import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/hooks/use_player_controller.dart';

/// The client half of the muffled-dialogue fix. The transcoder carries the
/// same rules in Go (`streaming.stereoDownmixFilter`) for the streams it
/// re-encodes; this one covers Direct Play, where the six channels reach the
/// device intact and mpv is the thing about to fold them down.
void main() {
  group('folding surround into stereo', () {
    test('never names a channel, so 5.1 and 5.1(side) both survive', () {
      // A six-channel film is tagged `5.1` by one muxer and `5.1(side)` by the
      // next — same order, different names for the rear pair — and `pan`
      // rejects a graph naming a channel the input layout does not carry. Index
      // addressing is what makes one filter correct for both.
      for (final channels in [6, 8]) {
        final filter = PlayerController.stereoDownmixFilter(channels);
        for (final name in ['FL', 'FR', 'FC', 'LFE', 'BL', 'BR', 'SL', 'SR']) {
          expect(filter, isNot(contains(name)),
              reason: '$channels-channel filter names $name');
        }
      }
    });

    test('lifts the centre to the level of the fronts', () {
      // The whole complaint: FFmpeg's normalised downmix leaves the centre at
      // 0.29 against the fronts' 0.41, so speech sits under the music.
      final filter = PlayerController.stereoDownmixFilter(6);
      expect(filter, contains('0.8*c2')); // centre
      expect(filter, contains('0.8*c0')); // front left
      expect(filter, contains('0.8*c1')); // front right
    });

    test('carries a limiter, since the coefficients sum past 1.0', () {
      for (final channels in [3, 6, 7, 8]) {
        expect(PlayerController.stereoDownmixFilter(channels),
            contains('alimiter='));
      }
    });

    test('leaves the routing alone when the layout is ambiguous', () {
      // 3, 4 and 7 channels each mean more than one thing, so there is no index
      // map worth trusting — only the lost level can be given back.
      for (final channels in [3, 4, 7]) {
        final filter = PlayerController.stereoDownmixFilter(channels);
        expect(filter, isNot(contains('pan=')));
        expect(filter, contains('volume='));
      }
    });

    test('is a graph mpv will accept as an `af` value', () {
      for (final channels in [3, 6, 8]) {
        final filter = PlayerController.stereoDownmixFilter(channels);
        expect(filter, startsWith('lavfi=['));
        expect(filter, endsWith(']'));
      }
    });
  });
}
