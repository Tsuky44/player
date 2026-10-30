import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/models/server_activity.dart';
import 'package:onyx/screens/player/hooks/playback_reporter.dart';
import 'package:onyx/screens/player/playback/playback_stats.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/client_log.dart';
import 'package:onyx/services/pending_playback_logs.dart';

/// Un serveur qui note ce qu'on lui envoie, dans l'ordre.
class _RecordingApi extends ApiClient {
  final List<String> calls = [];
  bool? lastFinished;
  bool failUploads = false;
  final List<int?> historyIds = [];

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
  Future<int?> uploadPlaybackLogs(List<LogEntry> lines,
      {Map<String, dynamic>? stats, int? historyId}) async {
    calls.add('logs');
    historyIds.add(historyId);
    if (failUploads) throw Exception('hors ligne');
    return 42;
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
    SharedPreferences.setMockInitialValues({});
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

  // La TV éteinte sur le lecteur, un épisode vu sur le téléphone, puis la TV
  // rallumée et quittée : sa position périmée écrasait celle du téléphone.
  test('une progression cédée ne s\'écrit plus en quittant', () async {
    reporter.open(mediaId: 1, apiClient: api);
    await reporter.suspend(mediaId: 1, apiClient: api);
    expect(api.calls.where((c) => c.startsWith('progress@')), hasLength(1));

    reporter.startHeartbeat(mediaId: 1, apiClient: api, announce: false);
    await reporter.finish(mediaId: 1, apiClient: api);
    reporter.cancelHeartbeat();
    expect(api.calls.where((c) => c.startsWith('progress@')), hasLength(1));
  });

  test('relire reprend la main sur la progression', () async {
    reporter.open(mediaId: 1, apiClient: api);
    reporter.yieldProgress();
    reporter.reclaimProgress();
    await reporter.finish(mediaId: 1, apiClient: api);
    expect(api.calls, contains('progress@120'));
  });

  test('la séance rouverte au retour à l\'écran ne coupe pas les autres',
      () async {
    reporter.startHeartbeat(mediaId: 1, apiClient: api, announce: false);
    reporter.cancelHeartbeat();
    await settle();
    expect(api.calls, ['playing:progress@120']);
  });

  // Une lecture sans journal : l'app coupée du réseau juste avant sa
  // fermeture. La tranche attend sur disque, nommée par la ligne d'historique
  // apprise au premier envoi, et repart à la lecture suivante.
  test('un envoi raté est rejoué au lancement suivant, vers la même ligne',
      () async {
    reporter.open(mediaId: 1, apiClient: api);
    reporter.flushLogs(api);
    for (var i = 0; i < 5; i++) {
      await settle();
    }
    expect(api.historyIds, [null]);

    api.failUploads = true;
    reporter.stop(mediaId: 1, apiClient: api);
    for (var i = 0; i < 10; i++) {
      await settle();
    }
    expect(api.historyIds, [null, 42]);

    api.failUploads = false;
    api.historyIds.clear();
    final next = PlaybackReporter(
      moment: () => (
        positionSeconds: 0,
        durationSeconds: 1000,
        playing: true,
        method: PlayMethod.direct,
        quality: '',
      ),
      stats: PlaybackStatsCollector(),
    );
    next.open(mediaId: 2, apiClient: api);
    for (var i = 0; i < 10; i++) {
      await settle();
    }
    expect(api.historyIds, [42]);

    api.historyIds.clear();
    await PendingPlaybackLogs.replay(api);
    expect(api.historyIds, isEmpty, reason: 'la tranche rejouée est effacée');
  });

  test('les envois suivants nomment la ligne historique déjà apprise',
      () async {
    reporter.open(mediaId: 1, apiClient: api);
    reporter.flushLogs(api);
    for (var i = 0; i < 5; i++) {
      await settle();
    }
    reporter.flushLogs(api);
    for (var i = 0; i < 5; i++) {
      await settle();
    }
    expect(api.historyIds, [null, 42]);
  });
}
