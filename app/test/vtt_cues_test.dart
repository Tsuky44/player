import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/vtt_cues.dart';

const _vtt = '''WEBVTT

NOTE produced by the server

1
00:00:01.000 --> 00:00:03.500 line:90%
<i>Bonjour</i> &amp; bienvenue

00:02.000 --> 00:04.000
Une autre voix
sur deux lignes

00:00:10.000 --> 00:00:09.000
à l'envers, ignorée
''';

void main() {
  final cues = VttCues.parse(_vtt);

  test('nothing is on screen before the first cue', () {
    expect(cues.linesAt(const Duration(milliseconds: 500)), isEmpty);
  });

  test('tags and entities are stripped, settings after the end time ignored',
      () {
    expect(cues.linesAt(const Duration(seconds: 1)), ['Bonjour & bienvenue']);
  });

  test('overlapping cues stack in file order', () {
    expect(cues.linesAt(const Duration(milliseconds: 2500)), [
      'Bonjour & bienvenue',
      'Une autre voix',
      'sur deux lignes',
    ]);
  });

  test('a cue is gone at its end time', () {
    expect(cues.linesAt(const Duration(milliseconds: 3500)),
        ['Une autre voix', 'sur deux lignes']);
    expect(cues.linesAt(const Duration(seconds: 4)), isEmpty);
  });

  test('a cue that ends before it starts is dropped', () {
    expect(cues.linesAt(const Duration(milliseconds: 9500)), isEmpty);
  });

  test('timestamps with and without hours', () {
    expect(parseVttTimestamp('01:02:03.456'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 456));
    expect(parseVttTimestamp('02:03.4'),
        const Duration(minutes: 2, seconds: 3, milliseconds: 400));
    expect(parseVttTimestamp('nope'), isNull);
  });
}
