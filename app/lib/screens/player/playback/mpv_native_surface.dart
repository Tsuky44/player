import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:onyx_mpv_macos/onyx_mpv_macos.dart';

import '../../../utils/app_platform.dart';
import '../player_engine.dart';
import 'mpv_subtitle_overlay.dart';
import 'mpv_window_host.dart';
import 'native_video_framing.dart';

/// Le cadrage demandé par l'écran, traduit en options mpv.
///
/// mpv dessine lui-même dans sa vue : c'est donc lui qui fait le letterbox ou
/// le recadrage, pas Flutter, qui ne voit qu'une vue native.
///
/// Le cadre se place comme partout ailleurs, par
/// [NativeVideoFraming.frameRect], puis se dit à mpv en zoom et en décalage à
/// partir de l'image entière, qu'il pose de lui-même : `video-zoom` en log₂,
/// `video-pan-*` en fractions de l'image agrandie. C'est ce qui lui fait
/// retirer des bandes incrustées hors du centre, ce que `panscan` ne sait pas
/// (ADR-0067). Sans rapport ni place connus, seul `cover` rogne, par
/// `panscan` : mpv, lui, connaît l'image et remplit juste.
abstract final class MpvFraming {
  static Map<String, String> properties(
    BoxFit fit,
    double? aspectRatio, {
    Size box = Size.zero,
    Rect? activeArea,
  }) {
    final aspectOverride =
        aspectRatio != null && aspectRatio > 0 ? '$aspectRatio' : 'no';
    if (fit == BoxFit.fill) {
      return _options('no', '0.0', aspectOverride);
    }
    if (aspectRatio == null || aspectRatio <= 0 || box.isEmpty) {
      return _options('yes', fit == BoxFit.cover ? '1.0' : '0.0', aspectOverride);
    }
    final rect = NativeVideoFraming.frameRect(
      fit,
      aspectRatio,
      box,
      activeArea: activeArea,
    );
    final whole = NativeVideoFraming.framedSize(BoxFit.contain, aspectRatio, box);
    return _options(
      'yes',
      '0.0',
      aspectOverride,
      zoom: math.log(rect.width / whole.width) / math.ln2,
      panX: (rect.center.dx - box.width / 2) / rect.width,
      panY: (rect.center.dy - box.height / 2) / rect.height,
    );
  }

  static Map<String, String> _options(
    String keepAspect,
    String panscan,
    String aspectOverride, {
    double zoom = 0,
    double panX = 0,
    double panY = 0,
  }) {
    // Arrondi : l'écran se reconstruit à chaque seconde, et une option qui
    // change dans sa sixième décimale serait renvoyée à mpv à chaque fois.
    String fixed(double value) {
      final text = value.toStringAsFixed(4);
      return text == '-0.0000' ? '0.0000' : text;
    }

    return {
      'keepaspect': keepAspect,
      'panscan': panscan,
      'video-aspect-override': aspectOverride,
      'video-zoom': fixed(zoom),
      'video-pan-x': fixed(panX),
      'video-pan-y': fixed(panY),
    };
  }
}

/// La surface de mpv quand il dessine dans une vue native ([MpvHostView]),
/// avec les sous-titres texte par-dessus.
class MpvNativeSurface extends StatefulWidget {
  const MpvNativeSurface({
    super.key,
    required this.engine,
    required this.fit,
    required this.subtitleKey,
    this.aspectRatio,
    this.activeArea,
  });

  final PlayerEngine engine;
  final BoxFit fit;
  final double? aspectRatio;
  final Rect? activeArea;
  final GlobalKey<MpvSubtitleOverlayState> subtitleKey;

  @override
  State<MpvNativeSurface> createState() => _MpvNativeSurfaceState();
}

class _MpvNativeSurfaceState extends State<MpvNativeSurface> {
  /// Les options déjà portées à mpv : l'écran se reconstruit à chaque seconde,
  /// mpv n'est appelé que quand le cadrage change vraiment.
  Map<String, String>? _applied;

  /// Recalculé à chaque mise en page : « Remplir la hauteur » rogne ou non
  /// selon la forme de la fenêtre, qu'on peut retailler en cours de film.
  void _syncFraming(Size box) {
    final properties = MpvFraming.properties(
      widget.fit,
      widget.aspectRatio,
      box: box,
      activeArea: widget.activeArea,
    );
    if (mapEquals(properties, _applied)) return;
    _applied = properties;
    final engine = widget.engine;
    unawaited(() async {
      final output = await engine.nativeOutput;
      for (final entry in properties.entries) {
        await output.setProperty(entry.key, entry.value);
      }
    }()
        .catchError((Object error) {
      debugPrint('mpv: cadrage refusé: $error');
      // Réessayé à la mise en page suivante plutôt que tenu pour appliqué.
      _applied = null;
    }));
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    return LayoutBuilder(builder: (context, constraints) {
      _syncFraming(constraints.biggest);
      return _surface(engine);
    });
  }

  Widget _surface(PlayerEngine engine) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (AppPlatform.isWindows)
          // Pas de vue native sous Windows : une fenêtre mpv sous celle de
          // l'app, vue à travers un trou (ADR-0061).
          MpvWindowHost(
            setProperty: (name, value) async {
              final output = await engine.nativeOutput;
              await output.setProperty(name, value);
            },
          )
        else
          MpvHostView(
            onAttach: (view) async {
              final output = await engine.nativeOutput;
              await output.attach(view);
            },
            onDetach: (view) async {
              final output = await engine.nativeOutput;
              await output.detach(view);
            },
          ),
        MpvSubtitleOverlay(key: widget.subtitleKey, player: engine.player),
      ],
    );
  }
}
