import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/playback/mpv_startup_trace.dart';

void main() {
  const t = Duration(milliseconds: 1234);

  test('keeps the path to the first frame, stamped from the open', () {
    final trace = MpvStartupTrace();
    expect(trace.line('cplayer', 'v', 'Starting playback...', t),
        'mpv +1234ms [cplayer] Starting playback...');
    expect(trace.line('demux', 'v', 'Detected file format: mkv', t), isNotNull);
    expect(trace.line('ffmpeg/demuxer', 'info', 'something', t), isNotNull);
    expect(trace.line('ao/wasapi', 'v', 'Format: 48000Hz', t), isNotNull);
  });

  test('drops the video output, which details every shader', () {
    expect(
        MpvStartupTrace().line('vo/gpu', 'v', 'compiling shader', t), isNull);
  });

  test('drops debug and trace, which log every packet', () {
    expect(MpvStartupTrace().line('demux', 'debug', 'packet', t), isNull);
    expect(MpvStartupTrace().line('demux', 'trace', 'packet', t), isNull);
  });

  test("drops the app's own commands echoed back", () {
    expect(
        MpvStartupTrace().line('cplayer', 'v', 'Set property: hr-seek -> 1', t),
        isNull);
  });

  test('masks the stream URL, which carries the playback ticket', () {
    final line = MpvStartupTrace().line('cplayer', 'info',
        'Playing: http://host:8080/stream?media_id=3&ticket=abcdef', t)!;
    expect(line, isNot(contains('abcdef')));
    expect(line, contains('[URL masquée]'));
  });

  test('stops at the ceiling and says how much it cut', () {
    final trace = MpvStartupTrace(maxLines: 2);
    expect(trace.summary(), isNull);
    for (var i = 0; i < 5; i++) {
      trace.line('demux', 'v', 'line $i', t);
    }
    expect(trace.line('demux', 'v', 'one more', t), isNull);
    expect(trace.summary(), contains('4 lignes'));
  });

  group('landing summary', () {
    test(
        'says where it landed against the asked point, and how fast bytes came',
        () {
      final line = MpvStartupProbe.describeLanding(
        at: const Duration(milliseconds: 4200),
        requestedStart: const Duration(seconds: 1520),
        keyframeStart: true,
        landedAt: 1516.3,
        aheadSeconds: 3.1,
        aheadBytes: 5.6e6,
        bytesPerSecond: 2e6,
      );
      expect(
          line,
          'mpv: bilan du démarrage à +4200ms — posée à 1516.3s pour '
          '1520s demandées (image clé, écart -3.7s) · 3.1s en avance (5.6 Mo) '
          '· réception 16.0 Mb/s');
    });

    test('leaves out what mpv did not answer', () {
      expect(
        MpvStartupProbe.describeLanding(
            at: const Duration(milliseconds: 900), keyframeStart: false),
        'mpv: bilan du démarrage à +900ms',
      );
    });
  });
}
