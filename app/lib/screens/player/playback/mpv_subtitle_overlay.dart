import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;

/// Les sous-titres texte, au-dessus de la vue native de mpv.
///
/// Le `SubtitleView` de media_kit vit dans son widget `Video` et exige un
/// `VideoController` — c'est-à-dire la texture qu'on quitte justement. Même
/// rendu et mêmes valeurs par défaut que lui, pour que rien ne change à
/// l'écran d'une plateforme à l'autre.
class MpvSubtitleOverlay extends StatefulWidget {
  const MpvSubtitleOverlay({super.key, required this.player});

  final mk.Player player;

  @override
  MpvSubtitleOverlayState createState() => MpvSubtitleOverlayState();
}

class MpvSubtitleOverlayState extends State<MpvSubtitleOverlay> {
  static const _style = TextStyle(
    height: 1.4,
    fontSize: 32.0,
    letterSpacing: 0.0,
    wordSpacing: 0.0,
    color: Color(0xffffffff),
    fontWeight: FontWeight.normal,
    backgroundColor: Color(0xaa000000),
  );

  /// La taille à laquelle [_style] est écrit ; le texte rétrécit en dessous.
  static const _referenceArea = 1920.0 * 1080.0;

  late List<String> _lines = widget.player.state.subtitle;
  EdgeInsets _padding = const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 24.0);
  Duration _duration = const Duration(milliseconds: 100);
  StreamSubscription<List<String>>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.player.stream.subtitle.listen((lines) {
      setState(() => _lines = lines);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void setPadding(
    EdgeInsets padding, {
    Duration duration = const Duration(milliseconds: 100),
  }) {
    setState(() {
      _padding = padding;
      _duration = duration;
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final area = constraints.maxWidth * constraints.maxHeight;
            final scale = sqrt((area / _referenceArea).clamp(0.0, 1.0));
            return AnimatedContainer(
              padding: _padding,
              duration: _duration,
              alignment: Alignment.bottomCenter,
              child: Text(
                [
                  for (final line in _lines)
                    if (line.trim().isNotEmpty) line.trim(),
                ].join('\n'),
                style: _style,
                textAlign: TextAlign.center,
                textScaler: TextScaler.linear(scale),
              ),
            );
          },
        ),
      ),
    );
  }
}
