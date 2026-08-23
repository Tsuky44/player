import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/hooks/use_player_controller.dart';

/// The client half of the dialogue-forward downmix. The transcoder carries the
/// same three numbers in Go (`streaming.stereoDownmixFilter`) for the streams
/// it re-encodes; this one covers Direct Play, where the six channels reach the
/// device intact and mpv is the thing about to fold them down.
///
/// What is being protected here is that the correction rides on swresample and
/// never on a filter graph. The libmpv media_kit ships for Android is built
/// against a minimal libavfilter with no `pan`, no `aformat` and no `alimiter`;
/// a graph naming any of them does not degrade, it leaves the file playing with
/// no sound at all.
void main() {
  const levels = PlayerController.dialogueForwardMixLevels;

  group('folding surround into stereo', () {
    test('lifts the centre to the level of the fronts', () {
      // The whole complaint: the default downmix carries the centre — the one
      // channel the dialogue is in — at 0.707 against the fronts' 1.0.
      expect(levels, contains('center_mix_level=1.0'));
    });

    test('leaves the rest of the mix where the film put it', () {
      // The surrounds keep the standard coefficient; the LFE, dropped entirely
      // by default, comes back low enough to add weight and no more.
      expect(levels, contains('surround_mix_level=0.7'));
      expect(levels, contains('lfe_mix_level=0.3'));
    });

    test('names no filter, so a minimal libavfilter cannot fail it', () {
      for (final filter in ['pan=', 'aformat', 'alimiter', 'lavfi']) {
        expect(levels, isNot(contains(filter)),
            reason: '$filter has to exist in the build to be used');
      }
    });

    test('names no channel, so it applies to any layout that arrives', () {
      // Mix levels are applied by the rematrix itself, so there is no channel
      // index to be wrong about — which is what lets this be set once, before
      // the file opens, when the layout is not yet known.
      for (final name in ['c0', 'c1', 'c2', 'FL', 'FC', 'LFE', 'BL', 'SL']) {
        expect(levels, isNot(contains(name)), reason: 'levels name $name');
      }
    });

    test('is a key/value list mpv will accept for audio-swresample-o', () {
      for (final pair in levels.split(',')) {
        expect(pair.split('=').length, 2, reason: 'malformed pair "$pair"');
        expect(double.tryParse(pair.split('=')[1]), isNotNull);
      }
    });
  });
}
