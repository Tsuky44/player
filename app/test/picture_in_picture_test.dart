import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/picture_in_picture.dart';

void main() {
  group('the shape of the little window', () {
    test('a normal film keeps its own shape', () {
      expect(PictureInPicture.shapeFor(1920, 1080), (1920, 1080));
      expect(PictureInPicture.shapeFor(1440, 1080), (1440, 1080));
    });

    test('a scope film is brought inside what Android accepts', () {
      // Android refuses a ratio outside 1:2.39 … 2.39:1 — it throws rather
      // than clamping — and 2.39:1 is exactly the shape of a scope film, so
      // the arithmetic has to land inside the range and not on its edge.
      final (width, height) = PictureInPicture.shapeFor(2560, 1040);
      expect(width / height, lessThanOrEqualTo(2.39));
      expect(height, 1040);
    });

    test('a vertical video is brought inside it the other way up', () {
      // A phone film, taller than Android will carry.
      final (width, height) = PictureInPicture.shapeFor(1080, 3000);
      expect(width / height, greaterThanOrEqualTo(1 / 2.39));
      expect(width, 1080);
      expect(height, lessThan(3000));
    });

    test('a portrait video that already fits is left alone', () {
      expect(PictureInPicture.shapeFor(1080, 1920), (1080, 1920));
    });

    test('an unknown size disarms rather than guessing', () {
      // Zero is how the player says "not now" — no film open, or one that has
      // not reported its size yet.
      expect(PictureInPicture.shapeFor(0, 0), (0, 0));
      expect(PictureInPicture.shapeFor(1920, 0), (0, 0));
    });
  });
}
