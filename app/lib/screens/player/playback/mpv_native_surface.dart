import 'dart:async';

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
/// mpv ne connaît que l'image entière (`panscan` à 0) ou la vue remplie (à
/// 1) : tout autre cadrage s'y ramène d'après [box], la place de la vue — voir
/// [NativeVideoFraming.crops]. Sans rapport connu, seul `cover` rogne : mpv,
/// lui, connaît l'image et remplit juste.
abstract final class MpvFraming {
  static Map<String, String> properties(
    BoxFit fit,
    double? aspectRatio, {
    Size box = Size.zero,
  }) {
    final known = aspectRatio != null && aspectRatio > 0 && !box.isEmpty;
    final crops = known
        ? NativeVideoFraming.crops(fit, aspectRatio, box)
        : fit == BoxFit.cover;
    final (keepAspect, panscan) = fit == BoxFit.fill
        ? ('no', '0.0')
        : ('yes', crops ? '1.0' : '0.0');
    return {
      'keepaspect': keepAspect,
      'panscan': panscan,
      'video-aspect-override':
          aspectRatio != null && aspectRatio > 0 ? '$aspectRatio' : 'no',
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
  });

  final PlayerEngine engine;
  final BoxFit fit;
  final double? aspectRatio;
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
