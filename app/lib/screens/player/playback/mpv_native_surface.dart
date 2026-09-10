import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:onyx_mpv_macos/onyx_mpv_macos.dart';

import '../player_engine.dart';
import 'mpv_subtitle_overlay.dart';

/// Le cadrage demandé par l'écran, traduit en options mpv.
///
/// mpv dessine lui-même dans sa vue : c'est donc lui qui fait le letterbox ou
/// le recadrage, pas Flutter, qui ne voit qu'une vue native.
abstract final class MpvFraming {
  static Map<String, String> properties(BoxFit fit, double? aspectRatio) {
    final (keepAspect, panscan) = switch (fit) {
      BoxFit.cover => ('yes', '1.0'),
      BoxFit.fill => ('no', '0.0'),
      _ => ('yes', '0.0'),
    };
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
  @override
  void initState() {
    super.initState();
    _applyFraming();
  }

  @override
  void didUpdateWidget(MpvNativeSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fit != widget.fit ||
        oldWidget.aspectRatio != widget.aspectRatio) {
      _applyFraming();
    }
  }

  void _applyFraming() {
    final properties = MpvFraming.properties(widget.fit, widget.aspectRatio);
    final engine = widget.engine;
    unawaited(() async {
      final output = await engine.nativeOutput;
      for (final entry in properties.entries) {
        await output.setProperty(entry.key, entry.value);
      }
    }()
        .catchError((Object error) {
      debugPrint('mpv: cadrage refusé: $error');
    }));
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    return Stack(
      fit: StackFit.expand,
      children: [
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
