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

  group('webQualityFor', () {
    test('caps a source the server cannot repackage to the surface', () {
      // The case this ceiling exists for: 4K HEVC on a 1080p window. Asking for
      // 2160p means a full libx264 encode of 8 megapixels per frame — measured
      // at 3 to 6 seconds before the first frame — for pixels nothing can show.
      expect(
        webQualityFor(
            sourceHeight: 2160, viewportHeight: 1080, sourceCodec: 'hevc'),
        '1080p',
      );
      expect(
        webQualityFor(
            sourceHeight: 2160, viewportHeight: 800, sourceCodec: 'hevc'),
        '1080p',
      );
      expect(
        webQualityFor(
            sourceHeight: 2160, viewportHeight: 700, sourceCodec: 'hevc'),
        '720p',
      );
    });

    test('leaves a repackageable source at its native tier', () {
      // Scaling is what forbids the repackaging, so capping here would trade a
      // copy that costs the server nothing for a 4K→1080p encode. For these
      // files the biggest tier is the FASTEST one to start.
      for (final codec in ['h264', 'avc1', 'H264']) {
        expect(
          webQualityFor(
              sourceHeight: 2160, viewportHeight: 1080, sourceCodec: codec),
          '2160p',
          reason: '$codec must keep its native tier',
        );
      }
    });

    test('never asks for more than the source has', () {
      // A big window does not invent resolution.
      expect(
        webQualityFor(
            sourceHeight: 720, viewportHeight: 2160, sourceCodec: 'hevc'),
        '720p',
      );
      expect(
        webQualityFor(
            sourceHeight: 1080, viewportHeight: 4320, sourceCodec: 'vp9'),
        '1080p',
      );
    });

    test('a 4K surface still gets 4K', () {
      expect(
        webQualityFor(
            sourceHeight: 2160, viewportHeight: 2160, sourceCodec: 'hevc'),
        '2160p',
      );
    });

    test('applies no ceiling when the surface is unknown', () {
      // 0 comes from a platform view that has not reported a size yet; guessing
      // small there would quietly downgrade every session on that path.
      expect(
        webQualityFor(sourceHeight: 2160, viewportHeight: 0, sourceCodec: 'hevc'),
        '2160p',
      );
    });
  });
}
