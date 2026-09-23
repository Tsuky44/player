import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/server_activity.dart';
import 'package:onyx/screens/player/hooks/playback_reporter.dart';
import 'package:onyx/screens/player/playback/playback_stats.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/client_log.dart';

/// Un serveur qui note ce qu'on lui envoie, dans l'ordre.
class _RecordingApi extends ApiClient {
  final List<String> calls = [];
  bool? lastFinished;

  @override
  Future<void> reportPlayback({
    required int mediaId,
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
    required PlayMethod playMethod,
    String quality = '',
    String event = 'progress',
  }) async {
    calls.add('playing:$event@$positionSeconds');
  }

  @override
  Future<void> uploadPlaybackLogs(List<LogEntry> lines,
      {Map<String, dynamic>? stats}) async {
    calls.add('logs');
  }

  @override
  Future<bool> sendProgress({
    required int mediaId,
    required int currentPositionSeconds,
    required int duration,
    required bool isFinished,
    DateTime? clientUpdatedAt,
  }) async {
    calls.add('progress@$currentPositionSeconds');
    lastFinished = isFinished;
    return isFinished;
  }
}

void main() {
  late _RecordingApi api;
  late int position;
  late PlaybackReporter reporter;

  setUp(() {
    api = _RecordingApi();
    position = 120;
    reporter = PlaybackReporter(
      moment: () => (
        positionSeconds: position,
        durationSeconds: 1000,
        playing: true,
        method: PlayMethod.direct,
        quality: '',
      ),
      stats: PlaybackStatsCollector(),
    );
    reporter.markLogStart();
    ClientLog.error('une panne à retrouver');
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('le journal part avant le signal qui ferme la séance', () async {
    reporter.open(mediaId: 1, apiClient: api);
    reporter.stop(mediaId: 1, apiClient: api);
    for (var i = 0; i < 5; i++) {
      await settle();
    }
    expect(api.calls, ['playing:start@120', 'logs', 'playing:stop@120']);
  });

  test('la séance ne se ferme qu\'une fois', () async {
    reporter.open(mediaId: 1, apiClient: api);
    reporter.stop(mediaId: 1, apiClient: api);
    reporter.stop(mediaId: 1, apiClient: api);
    for (var i = 0; i < 5; i++) {
      await settle();
    }
    expect(api.calls.where((c) => c.startsWith('playing:stop')), hasLength(1));
  });

  test('la fin marque vu au-delà de 90 %, et décrit l\'instant de l\'envoi',
      () async {
    reporter.open(mediaId: 1, apiClient: api);
    position = 950;
    await reporter.finish(mediaId: 1, apiClient: api);
    expect(api.calls, contains('progress@950'));
    expect(api.lastFinished, isTrue);
  });
}
