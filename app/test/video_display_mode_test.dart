import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/native_video_framing.dart';
import 'package:onyx/screens/player/video_display_mode.dart';

/// Les modes d'affichage ne sont que des zooms : ce qu'ils promettent se
/// vérifie sur la géométrie de l'image cadrée. Voir ADR-0063.
void main() {
  const tv = Size(1920, 1080);
  const scope = 2.39;
  const episode = 16 / 9;
  const academy = 4 / 3;

  Size framed(VideoDisplayMode mode, double aspect, [Size box = tv]) =>
      NativeVideoFraming.framedSize(mode.fit, aspect, box);

  group('aucun mode ne déforme l\'image', () {
    for (final mode in VideoDisplayMode.values) {
      for (final aspect in [scope, episode, academy]) {
        test('${mode.name} garde le rapport $aspect', () {
          final size = framed(mode, aspect);
          expect(size.width / size.height, closeTo(aspect, 0.001));
        });
      }
    }
  });

  group('« Original »', () {
    test('montre l\'image entière', () {
      final size = framed(VideoDisplayMode.original, scope);
      expect(size.width, tv.width);
      expect(size.height, lessThan(tv.height));
    });
  });

  group('« Remplir la hauteur »', () {
    test('supprime les bandes du haut et du bas d\'un film large', () {
      final size = framed(VideoDisplayMode.fillHeight, scope);
      expect(size.height, tv.height);
      expect(size.width, greaterThan(tv.width));
    });

    test('garde les bandes des côtés d\'un film étroit', () {
      // Les bandes des côtés ne sont pas les siennes : un 4:3 reste entier.
      final size = framed(VideoDisplayMode.fillHeight, academy);
      expect(size.height, tv.height);
      expect(size.width, lessThan(tv.width));
    });
  });

  group('« Remplir l\'écran »', () {
    test('ne laisse aucune bande, quelle que soit la forme du film', () {
      for (final aspect in [scope, academy]) {
        final size = framed(VideoDisplayMode.fill, aspect);
        expect(size.width, greaterThanOrEqualTo(tv.width));
        expect(size.height, greaterThanOrEqualTo(tv.height));
      }
    });
  });

  test('les modes vont du moins zoomé au plus zoomé', () {
    for (final aspect in [scope, episode, academy]) {
      var previous = 0.0;
      for (final mode in VideoDisplayMode.values) {
        final width = framed(mode, aspect).width;
        expect(width, greaterThanOrEqualTo(previous));
        previous = width;
      }
    }
  });

  test('un cran de zoom s\'arrête aux deux bouts', () {
    expect(VideoDisplayMode.original.zoomedOut, VideoDisplayMode.original);
    expect(VideoDisplayMode.original.zoomedIn, VideoDisplayMode.fillHeight);
    expect(VideoDisplayMode.fillHeight.zoomedIn, VideoDisplayMode.fill);
    expect(VideoDisplayMode.fill.zoomedIn, VideoDisplayMode.fill);
    expect(VideoDisplayMode.fill.zoomedOut, VideoDisplayMode.fillHeight);
  });

  group('le mode par défaut', () {
    VideoDisplayMode on(Size screen, {bool handheld = true}) =>
        VideoDisplayMode.defaultFor(handheld: handheld, screen: screen);

    test('un téléphone remplit sa hauteur', () {
      // Des bandes en haut et en bas d'un écran déjà petit, c'était payer le
      // cadrage là où l'image est la plus rare.
      expect(on(const Size(874, 402)), VideoDisplayMode.fillHeight);
    });

    test('une tablette montre l\'image entière', () {
      // En 4:3, remplir la hauteur d'un épisode 16:9 en rognait un quart de
      // chaque côté.
      expect(on(const Size(1180, 820)), VideoDisplayMode.original);
    });

    test('un téléviseur et un ordinateur montrent l\'image entière', () {
      expect(on(const Size(960, 540), handheld: false),
          VideoDisplayMode.original);
    });
  });
}
