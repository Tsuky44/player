import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:onyx_player_apple/onyx_player_apple.dart';

/// Les sous-titres image (PGS, VobSub, DVB), posés là où le disque les place.
///
/// Leur position arrive en fractions de l'image vidéo : ce widget doit donc
/// recouvrir exactement l'image, pas l'écran. Il vit dans le même cadre que la
/// vue native (`NativeVideoFraming`), et suit ainsi le cadrage choisi.
class SubtitleBitmapOverlay extends StatelessWidget {
  const SubtitleBitmapOverlay({super.key, required this.bitmaps});

  final ValueListenable<List<OnyxAppleSubtitleBitmap>> bitmaps;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<List<OnyxAppleSubtitleBitmap>>(
        valueListenable: bitmaps,
        builder: (context, images, _) {
          if (images.isEmpty) return const SizedBox.shrink();
          return LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;
              return Stack(
                children: [
                  for (final image in images)
                    Positioned(
                      left: image.left * w,
                      top: image.top * h,
                      width: image.width * w,
                      height: image.height * h,
                      child: Image.memory(
                        image.png,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
