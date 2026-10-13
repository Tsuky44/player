import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../utils/on_screen.dart';
import '../../../utils/win32_video_window_io.dart';

/// La surface vidéo de Windows quand mpv dessine lui-même avec `gpu-next`.
///
/// Flutter n'a pas de vue native sous Windows, donc nulle part où poser la
/// fenêtre de mpv dans l'arbre. Elle est placée *sous* la fenêtre de l'app, et
/// ce widget perce un trou à sa place : on voit mpv à travers, et les
/// contrôles se dessinent par-dessus comme sur n'importe quelle surface.
///
/// mpv ouvre sa fenêtre lui-même (sans `wid`) : elle a son propre fil et sa
/// propre boucle de messages, que rien dans l'app n'a à faire tourner.
class MpvWindowHost extends StatefulWidget {
  const MpvWindowHost({super.key, required this.setProperty});

  /// Pose une option de la sortie vidéo de mpv, hors du thread de l'interface.
  final Future<void> Function(String name, String value) setProperty;

  @override
  State<MpvWindowHost> createState() => _MpvWindowHostState();
}

class _MpvWindowHostState extends State<MpvWindowHost>
    with OnScreenState<MpvWindowHost> {
  /// Ce que cette minuterie suit, c'est la mise en page de Flutter — la place
  /// du widget dans la fenêtre. Les déplacements de la fenêtre elle-même sont
  /// suivis par le runner (`video_backdrop.h`), dans le message Windows qui
  /// les annonce : pendant un glissement, aucune minuterie Dart ne tourne.
  static const _followEvery = Duration(milliseconds: 16);

  Timer? _follow;
  int _appWindow = 0;
  int _videoWindow = 0;
  List<int>? _placed;
  bool _visible = true;

  /// Le trou n'est percé qu'une fois mpv en place : avant, on verrait le
  /// bureau à travers l'app.
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _appWindow = Win32VideoWindow.findOwn(Win32VideoWindow.flutterWindowClass);
    unawaited(_openVideoWindow());
  }

  /// La minuterie ne tourne que tant qu'on voit le lecteur. Fenêtre réduite
  /// ou lecteur recouvert, la fenêtre de mpv est cachée : seule, elle
  /// resterait posée sur le bureau.
  @override
  void didChangeOnScreen(bool onScreen) {
    _follow?.cancel();
    _follow = null;
    if (onScreen) {
      _follow = Timer.periodic(_followEvery, (_) => _sync());
    } else if (_videoWindow != 0 && _visible) {
      _visible = false;
      _placed = null;
      Win32VideoWindow.detach(_appWindow);
      Win32VideoWindow.setVisible(_videoWindow, false);
    }
  }

  Future<void> _openVideoWindow() async {
    // Tout ce qui fait d'une fenêtre mpv une fenêtre d'application est
    // coupé : ni bordure, ni focus, ni clavier, ni souris, ni curseur masqué.
    const window = {
      'border': 'no',
      'focus-on': 'never',
      'keepaspect-window': 'no',
      'input-default-bindings': 'no',
      'input-vo-keyboard': 'no',
      'input-cursor': 'no',
      'cursor-autohide': 'no',
      'taskbar-progress': 'no',
      // mpv remet sa fenêtre à la taille de la vidéo à chaque fichier ouvert.
      // App agrandie, elle sortait un peu plus petite que le lecteur, avec
      // une marge sur les côtés jusqu'au prochain redimensionnement.
      'auto-window-resize': 'no',
      // Laisse gpu-next passer l'écran en HDR quand il le peut.
      'target-colorspace-hint': 'yes',
      // La fenêtre existe dès que la sortie est créée, noire : sans ça elle
      // n'apparaît qu'à la première image, et le trou montrerait le bureau.
      'force-window': 'yes',
      'vo': 'gpu-next',
    };
    for (final entry in window.entries) {
      try {
        await widget.setProperty(entry.key, entry.value);
      } catch (e) {
        debugPrint('mpv: option ${entry.key}=${entry.value} refusée: $e');
      }
    }
  }

  void _sync() {
    if (!mounted || _appWindow == 0) return;
    // Le moteur est mis en commun : la fenêtre de la lecture précédente peut
    // encore être en train de se fermer quand celle-ci cherche la sienne.
    if (_videoWindow != 0 && !Win32VideoWindow.exists(_videoWindow)) {
      _videoWindow = 0;
      _placed = null;
    }
    if (_videoWindow == 0) {
      _videoWindow = Win32VideoWindow.findOwn(Win32VideoWindow.mpvWindowClass);
      if (_videoWindow == 0) return;
      Win32VideoWindow.makeBackdrop(_videoWindow);
    }

    final visible = !Win32VideoWindow.isMinimized(_appWindow);
    if (visible != _visible) {
      _visible = visible;
      Win32VideoWindow.setVisible(_videoWindow, visible);
    }
    if (!visible) return;

    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final ratio = View.of(context).devicePixelRatio;
    final origin = box.localToGlobal(Offset.zero) * ratio;
    final size = box.size * ratio;
    // La taille de la mise en page en cours, pas celle de la fenêtre : pendant
    // un redimensionnement, Windows et même `View.physicalSize` ont une image
    // d'avance sur elle, et l'écart passait pour une marge — mesuré, la vidéo
    // se décalait sur 30 pas de redimensionnement sur 80.
    RenderObject root = box;
    while (root.parent != null) {
      root = root.parent!;
    }
    if (root is! RenderView) return;
    final laidOut = root.size * ratio;
    final left = origin.dx.round();
    final top = origin.dy.round();
    final insets = [
      left,
      top,
      laidOut.width.round() - left - size.width.round(),
      laidOut.height.round() - top - size.height.round(),
    ];
    // Le rang et la place se revérifient à chaque passage : une autre
    // fenêtre peut s'être glissée entre les deux, et mpv peut avoir bougé la
    // sienne, sans que rien n'ait changé ici.
    if (!_sameInsets(insets) ||
        !Win32VideoWindow.isRightUnder(_videoWindow, _appWindow) ||
        !Win32VideoWindow.isInPlace(
            app: _appWindow, video: _videoWindow, insets: insets)) {
      _placed = insets;
      Win32VideoWindow.attach(
          app: _appWindow, video: _videoWindow, insets: insets);
    }
    if (!_ready) {
      Win32VideoWindow.setSeeThrough(_appWindow, true);
      setState(() => _ready = true);
    }
  }

  bool _sameInsets(List<int> insets) {
    final placed = _placed;
    if (placed == null) return false;
    for (var i = 0; i < insets.length; i++) {
      if (placed[i] != insets[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _follow?.cancel();
    if (_appWindow != 0) Win32VideoWindow.detach(_appWindow);
    // L'app redevient opaque avant que mpv ne ferme sa fenêtre : l'inverse
    // laisserait voir le bureau le temps d'une image.
    if (_appWindow != 0) Win32VideoWindow.setSeeThrough(_appWindow, false);
    final setProperty = widget.setProperty;
    unawaited(setProperty('vo', 'null').catchError((Object e) {
      debugPrint('mpv: sortie vidéo non rendue: $e');
    }));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _HolePainter(open: _ready),
        size: Size.infinite,
      );
}

/// Efface ce que Flutter a peint sous la surface — le fond noir du lecteur —
/// jusqu'à la transparence, pour laisser voir la fenêtre de mpv.
class _HolePainter extends CustomPainter {
  const _HolePainter({required this.open});

  final bool open;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(0xFF000000)
        ..blendMode = open ? BlendMode.clear : BlendMode.srcOver,
    );
  }

  @override
  bool shouldRepaint(_HolePainter oldDelegate) => oldDelegate.open != open;
}
