import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/hooks/use_player_controller.dart';

/// The client half of the dialogue-forward downmix. The transcoder carries the
/// same graph in Go (`streaming.stereoDownmixFilter`) for the streams it
/// re-encodes; this one covers Direct Play, where the six channels reach the
/// device intact and mpv is the thing about to fold them down.
///
/// The graph is a constant, and that is the point being protected here: the
/// version it replaced picked one filter per channel count, which meant the
/// layout had to be known before the filter could be installed — and it is not
/// known until mpv has configured the track, well after the file has started.
void main() {
  const filter = PlayerController.dialogueForwardDownmix;

  group('folding surround into stereo', () {
    test('normalises the layout before addressing channels by index', () {
      // `pan` reads `c4` as "the fifth channel of whatever arrived", so the
      // graph is only correct if the input is known to have six. `aformat`
      // is what makes that true for every track in the library — mono, stereo,
      // 5.1, 5.1(side) and 7.1 all reach `pan` as plain 5.1.
      expect(filter.indexOf('aformat=channel_layouts=5.1'),
          lessThan(filter.indexOf('pan=stereo')));
    });

    test('never names a channel, so 5.1 and 5.1(side) both survive', () {
      // A six-channel film is tagged `5.1` by one muxer and `5.1(side)` by the
      // next — same order, different names for the rear pair — and `pan`
      // rejects a graph naming a channel the input layout does not carry.
      for (final name in ['FL', 'FR', 'FC', 'LFE', 'BL', 'BR', 'SL', 'SR']) {
        expect(filter, isNot(contains(name)), reason: 'filter names $name');
      }
    });

    test('lifts the centre to the level of the fronts', () {
      // The whole complaint: the default downmix carries the centre at 0.707
      // against the fronts' 1.0, so speech sits 3 dB under the music. Carrying
      // both at 1.0 is +3 dB on dialogue and leaves everything else untouched —
      // measured on mpv's own output, not assumed.
      expect(filter, contains('c0=1.0*c0+1.0*c2')); // front left + centre
      expect(filter, contains('c1=1.0*c1+1.0*c2')); // front right + centre
    });

    test('carries a limiter, since the coefficients sum past 1.0', () {
      expect(filter, contains('alimiter='));
      expect(filter.indexOf('alimiter='), greaterThan(filter.indexOf('pan=')));
    });

    test('is a graph mpv will accept as an `af` value', () {
      expect(filter, startsWith('lavfi=['));
      expect(filter, endsWith(']'));
    });
  });
}
