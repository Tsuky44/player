import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Les sous-titres, dessinés par Flutter au-dessus de la surface vidéo.
///
/// mpv rend les siens lui-même, dans une vue que media_kit fournit ; ExoPlayer
/// remonte du texte, et c'est ici qu'il devient une image. L'habillage — la
/// taille, l'ombre portée en bandeau, la mise à l'échelle selon la surface —
/// reprend exactement celui de media_kit, pour qu'un même film ait la même
/// tête sur un téléphone Android et sur un Mac.
class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({
    super.key,
    required this.cues,
    required this.inset,
  });

  /// Les lignes à afficher maintenant. Vide la plupart du temps.
  final ValueListenable<List<String>> cues;

  /// De combien les remonter, et en combien de temps. La barre de progression
  /// s'ouvre et se ferme ; les sous-titres la suivent plutôt que de passer
  /// dessous.
  final ValueListenable<({EdgeInsets padding, Duration duration})> inset;

  /// Ce que media_kit pose par défaut.
  static const EdgeInsets defaultPadding = EdgeInsets.fromLTRB(16, 0, 16, 24);

  /// Le style de media_kit, repris tel quel. Le fond translucide est ce qui
  /// rend le texte lisible sur une image claire sans contour à dessiner.
  static const TextStyle style = TextStyle(
    height: 1.4,
    fontSize: 32,
    letterSpacing: 0,
    wordSpacing: 0,
    color: Color(0xFFFFFFFF),
    fontWeight: FontWeight.normal,
    backgroundColor: Color(0xAA000000),
  );

  /// La taille de référence à laquelle `fontSize` vaut ce qu'il dit. En
  /// dessous, le texte rétrécit avec la surface — sinon un sous-titre calibré
  /// pour un téléviseur mangerait la moitié d'un écran de téléphone.
  static const double _referenceWidth = 1920;
  static const double _referenceHeight = 1080;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = math.sqrt(
            ((constraints.maxWidth * constraints.maxHeight) /
                    (_referenceWidth * _referenceHeight))
                .clamp(0.0, 1.0),
          );

          return ValueListenableBuilder<List<String>>(
            valueListenable: cues,
            builder: (context, lines, _) {
              final text = [
                for (final line in lines)
                  if (line.trim().isNotEmpty) line.trim(),
              ].join('\n');
              if (text.isEmpty) return const SizedBox.shrink();

              return ValueListenableBuilder<
                  ({EdgeInsets padding, Duration duration})>(
                valueListenable: inset,
                builder: (context, value, _) {
                  return AnimatedContainer(
                    padding: value.padding,
                    duration: value.duration,
                    alignment: Alignment.bottomCenter,
                    child: Text(
                      text,
                      style: style,
                      textAlign: TextAlign.center,
                      textScaler: TextScaler.linear(scale),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
