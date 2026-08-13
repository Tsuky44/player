import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/web_quality.dart';

void main() {
  group('qualityForSourceHeight', () {
    test('serves each nominal resolution at its own tier', () {
      expect(qualityForSourceHeight(2160), '2160p');
      expect(qualityForSourceHeight(1080), '1080p');
      expect(qualityForSourceHeight(720), '720p');
      expect(qualityForSourceHeight(480), '480p');
      expect(qualityForSourceHeight(360), '360p');
    });

    test('keeps wide-aspect masters in their real tier', () {
      // A 2.39:1 film at 1920 wide is 804 lines tall, and a 4K one is 1608.
      // Demoting either would show the web a smaller picture than the app.
      expect(qualityForSourceHeight(804), '1080p');
      expect(qualityForSourceHeight(1608), '2160p');
      // 1.85:1 at 1920 wide.
      expect(qualityForSourceHeight(1038), '1080p');
    });

    test('never upscales a small source', () {
      expect(qualityForSourceHeight(576), '720p'); // PAL DVD
      expect(qualityForSourceHeight(480), '480p');
      expect(qualityForSourceHeight(240), '360p');
    });

    test('falls back when the probe reports no height', () {
      expect(qualityForSourceHeight(0), webFallbackQuality);
      expect(qualityForSourceHeight(-1), webFallbackQuality);
    });
  });
}
