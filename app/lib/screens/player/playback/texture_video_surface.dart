import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' show VideoParams;
import 'package:media_kit_video/media_kit_video.dart';

/// La surface du lecteur quand mpv dessine dans une texture Flutter, avec la
/// texture taillée à l'écran plutôt qu'au fichier.
///
/// Sans taille donnée, media_kit fait rendre mpv à la **résolution native du
/// média** : un film 4K est dessiné en 3840 de large même dans une fenêtre de
/// 1280, puis Flutter rééchantillonne cette texture à la taille voulue. Tout le
/// travail au-dessus de la taille d'affichage — mise à l'échelle, tone mapping,
/// débanding, la passe entière du renderer — est donc payé pour des pixels que
/// personne ne verra, et payé deux fois puisque Flutter redimensionne ensuite.
///
/// La texture suit donc la place réellement occupée, en pixels physiques, et ne
/// dépasse jamais la résolution du média : on ne demande pas à mpv d'agrandir
/// ce qu'il n'a pas. C'est mpv qui réduit, une fois, avec son propre scaler.
///
/// Le redimensionnement de la texture n'est pas gratuit — media_kit la
/// reconstruit — d'où l'attente après le dernier changement et le seuil en
/// dessous duquel on ne bouge pas : tirer le coin d'une fenêtre ne doit pas
/// reconstruire une texture à chaque image.
class TextureVideoSurface extends StatefulWidget {
  const TextureVideoSurface({
    super.key,
    required this.controller,
    required this.videoKey,
    required this.fit,
    this.aspectRatio,
  });

  final VideoController controller;
  final GlobalKey<VideoState> videoKey;
  final BoxFit fit;
  final double? aspectRatio;

  /// Le temps de calme avant de retailler la texture.
  static const Duration settleDelay = Duration(milliseconds: 250);

  /// En deçà, la différence ne vaut pas une reconstruction.
  static const int threshold = 64;

  /// La taille à demander, ou null quand la demande en cours fait l'affaire.
  ///
  /// Pure pour être vérifiable : c'est la règle, pas son ordonnancement.
  static ({int width, int height})? nextSize({
    required Size logical,
    required double pixelRatio,
    required int videoWidth,
    required int videoHeight,
    ({int width, int height})? current,
  }) {
    if (logical.isEmpty || pixelRatio <= 0) return null;
    if (videoWidth <= 0 || videoHeight <= 0) return null;

    // La hauteur seule suffirait — le rapport est celui du média — mais une
    // fenêtre plus large que haute donne une image bornée par sa hauteur, et
    // l'inverse par sa largeur. On prend donc la plus contraignante des deux.
    final scale = [
      (logical.width * pixelRatio) / videoWidth,
      (logical.height * pixelRatio) / videoHeight,
      1.0, // jamais d'agrandissement : mpv n'a pas ces pixels
    ].reduce((a, b) => a < b ? a : b);

    // Pair pour la chrominance 4:2:0, et jamais nul.
    int even(num value) {
      final rounded = value.round();
      return (rounded < 2 ? 2 : rounded) & ~1;
    }

    final next = (width: even(videoWidth * scale), height: even(videoHeight * scale));
    if (current == null) return next;
    if ((next.width - current.width).abs() < threshold &&
        (next.height - current.height).abs() < threshold) {
      // Sauf tout en haut : la pleine résolution est la seule taille qu'on
      // tient à atteindre exactement, sinon un plein écran resterait sous-résolu.
      final atNative = next.width == videoWidth && current.width != videoWidth;
      if (!atNative) return null;
    }
    return next;
  }

  @override
  State<TextureVideoSurface> createState() => _TextureVideoSurfaceState();
}

class _TextureVideoSurfaceState extends State<TextureVideoSurface> {
  ({int width, int height})? _applied;
  Timer? _settle;

  /// La dernière place connue, pour retailler quand le média, lui, change.
  Size? _logical;
  double _pixelRatio = 1;

  /// Les dimensions du média arrivent après le premier build : sans cette
  /// écoute, la texture n'était retaillée qu'à la reconstruction suivante de
  /// l'écran, et un film ouvert sans rien bouger restait rendu en 4K.
  StreamSubscription<VideoParams>? _videoParams;

  @override
  void initState() {
    super.initState();
    _listenToVideoParams();
  }

  @override
  void didUpdateWidget(TextureVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _applied = null;
      _listenToVideoParams();
    }
  }

  void _listenToVideoParams() {
    _videoParams?.cancel();
    _videoParams = widget.controller.player.stream.videoParams.listen((_) {
      final logical = _logical;
      if (mounted && logical != null) _requestSize(logical, _pixelRatio);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    _videoParams?.cancel();
    super.dispose();
  }

  void _requestSize(Size logical, double pixelRatio) {
    _logical = logical;
    _pixelRatio = pixelRatio;
    final params = widget.controller.player.state.videoParams;
    final size = TextureVideoSurface.nextSize(
      logical: logical,
      pixelRatio: pixelRatio,
      videoWidth: params.dw ?? params.w ?? 0,
      videoHeight: params.dh ?? params.h ?? 0,
      current: _applied,
    );
    if (size == null) return;

    _settle?.cancel();
    _settle = Timer(TextureVideoSurface.settleDelay, () async {
      if (!mounted) return;
      _applied = size;
      try {
        await widget.controller.setSize(width: size.width, height: size.height);
      } catch (e) {
        debugPrint('Video: texture ${size.width}x${size.height} refusée: $e');
        _applied = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Après la frame : `setSize` reconstruit la texture, ce qui n'a rien à
        // faire au milieu d'un build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _requestSize(constraints.biggest, pixelRatio);
        });
        return Video(
          key: widget.videoKey,
          controller: widget.controller,
          controls: null,
          fit: widget.fit,
          aspectRatio: widget.aspectRatio,
        );
      },
    );
  }
}
