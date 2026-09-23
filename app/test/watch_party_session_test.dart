import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/watch_party.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un serveur de séance en mémoire : chaque long-poll attend que le test lui
/// donne une réponse, et chaque geste est noté.
class _FakePartyApi extends ApiClient {
  final List<Completer<Map<String, dynamic>>> polls = [];
  final List<Map<String, Object?>> updates = [];
  int leaves = 0;
  Map<String, dynamic> Function(Map<String, Object?> update)? onUpdate;

  @override
  Future<Map<String, dynamic>> createWatchParty({
    required int mediaId,
    required double positionSeconds,
    required bool playing,
  }) async =>
      _party(version: 1, mediaId: mediaId, playing: playing,
          position: positionSeconds);

  /// Ce que rend une mesure de latence (un poll sur une version dépassée).
  Map<String, dynamic> current = _party(version: 1);

  @override
  Future<Map<String, dynamic>> pollWatchParty(
    String code, {
    required String memberId,
    required int since,
    CancelToken? cancelToken,
  }) {
    if (since == 0) return Future.value(current);
    final completer = Completer<Map<String, dynamic>>();
    polls.add(completer);
    return completer.future;
  }

  @override
  Future<Map<String, dynamic>> updateWatchParty(
    String code, {
    required String memberId,
    required String action,
    bool? playing,
    double? positionSeconds,
    int? mediaId,
    bool? loading,
  }) async {
    final update = {
      'action': action,
      'playing': playing,
      'position': positionSeconds,
      'media_id': mediaId,
      'loading': loading,
    };
    updates.add(update);
    return onUpdate!(update);
  }

  @override
  Future<void> leaveWatchParty(String code, {required String memberId}) async {
    leaves++;
  }
}

Map<String, dynamic> _party({
  required int version,
  int mediaId = 10,
  bool playing = true,
  double position = 100,
  String? actionKind,
  bool byYou = false,
  List<String> waitingFor = const [],
  bool waitingForYou = false,
}) =>
    {
      'code': 'ABC234',
      'member_id': 'me',
      'version': version,
      'media_id': mediaId,
      'media': {'id': mediaId, 'type': 'episode', 'title': 'Épisode $mediaId'},
      'playing': playing,
      'position_seconds': position,
      'waiting_for': waitingFor,
      'waiting_for_you': waitingForYou,
      'members': [
        {'username': 'moi', 'is_you': true, 'is_host': true},
        {'username': 'alex'},
      ],
      if (actionKind != null)
        'last_action': {
          'kind': actionKind,
          'username': byYou ? 'moi' : 'alex',
          'by_you': byYou,
          'version': version,
        },
    };

class _FakePlayer implements WatchPartyPlayer {
  _FakePlayer({this.mediaId = 10, int seconds = 100})
      : position = Duration(seconds: seconds);

  @override
  int mediaId;
  @override
  bool isPlaying = true;
  @override
  Duration position;
  @override
  bool isReady = true;
  @override
  bool isBusy = false;
  @override
  bool isLoading = false;

  final List<bool> playingApplied = [];
  final List<Duration> seeks = [];
  final List<int> opened = [];
  final List<double> rates = [];

  @override
  Future<void> applyRateFactor(double factor) async => rates.add(factor);

  @override
  Future<void> applyPlaying(bool playing) async {
    playingApplied.add(playing);
    isPlaying = playing;
  }

  @override
  Future<void> applySeek(Duration target) async {
    seeks.add(target);
    position = target;
  }

  @override
  void openMedia(HomeMediaItem media, Duration position,
      {required bool playing}) {
    opened.add(media.media.id);
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    await WatchPartySession.active.value?.leave();
  });

  Future<(WatchPartySession, _FakePartyApi)> open() async {
    final api = _FakePartyApi();
    final session = await WatchPartySession.create(
      api: api,
      accountId: 'server',
      mediaId: 10,
      position: const Duration(seconds: 100),
      playing: true,
    );
    await _settle();
    return (session, api);
  }

  test('a pause from someone else pauses this player, without echo', () async {
    final (session, api) = await open();
    final player = _FakePlayer();
    session.attach(player);
    final notices = <String>[];
    session.notices.listen(notices.add);

    api.polls.last.complete(
        _party(version: 2, playing: false, position: 100, actionKind: 'pause'));
    await _settle();

    expect(player.playingApplied, [false]);
    expect(api.updates, isEmpty, reason: 'a remote gesture must not be resent');
    expect(notices, ['alex a mis en pause']);
  });

  test('a far seek from someone else moves this player there', () async {
    final (session, api) = await open();
    final player = _FakePlayer();
    session.attach(player);

    api.polls.last.complete(
        _party(version: 2, position: 1500, actionKind: 'seek'));
    await _settle();

    expect(player.seeks, hasLength(1));
    expect(player.seeks.single.inSeconds, inInclusiveRange(1500, 1501));
  });

  test('a small lag is caught up by speed, not by a seek', () async {
    final (session, api) = await open();
    final player = _FakePlayer(seconds: 100);
    session.attach(player);

    api.polls.last.complete(_party(version: 2, position: 100.5));
    await _settle();

    expect(player.seeks, isEmpty);
    expect(player.rates, isNotEmpty);
    expect(player.rates.last, greaterThan(1));
    expect(player.rates.last, lessThanOrEqualTo(1.08));
  });

  test('a tiny drift is left alone', () async {
    final (session, api) = await open();
    final player = _FakePlayer(seconds: 100);
    session.attach(player);

    api.polls.last.complete(_party(version: 2, position: 100.02));
    await _settle();

    expect(player.seeks, isEmpty);
    expect(player.rates, isEmpty);
  });

  test('everyone pauses while someone else is loading', () async {
    final (session, api) = await open();
    final player = _FakePlayer();
    session.attach(player);

    api.polls.last.complete(
        _party(version: 2, position: 98, waitingFor: ['alex']));
    await _settle();

    expect(player.playingApplied, [false]);
    expect(player.seeks.single.inMilliseconds, 98000,
        reason: 'the party froze where alex stalled');
    expect(session.waitingMessage, 'En attente de alex…');
  });

  test('a device the party waits for keeps loading, then holds until the '
      'server lets everyone go', () async {
    final (session, api) = await open();
    final player = _FakePlayer()..isLoading = true;
    session.attach(player);
    api.onUpdate = (_) => _party(version: 3, position: 100);

    api.polls.last.complete(
        _party(version: 2, position: 100, waitingForYou: true));
    await _settle();
    expect(player.playingApplied, isEmpty,
        reason: 'a loading player is not paused for itself');

    player.isLoading = false;
    session.resync();
    await _settle();

    expect(api.updates.single['action'], 'loading');
    expect(api.updates.single['loading'], false);
    expect(player.playingApplied, [false, true],
        reason: 'held while the server had not answered, then released');
  });

  test('another episode chosen elsewhere is opened here', () async {
    final (session, api) = await open();
    final player = _FakePlayer();
    session.attach(player);

    api.polls.last.complete(
        _party(version: 2, mediaId: 11, position: 0, actionKind: 'media'));
    await _settle();

    expect(player.opened, [11]);
  });

  test('an episode chosen here is not undone before the server confirms it',
      () async {
    final (session, api) = await open();
    final old = _FakePlayer();
    session.attach(old);

    api.onUpdate = (_) => _party(version: 2, mediaId: 11, position: 0);
    // The next episode's player attaches before the answer comes back, while
    // the party still says episode 10.
    session.detach(old);
    final sent = session.sendMedia(11);
    final next = _FakePlayer(mediaId: 11, seconds: 0);
    session.attach(next);
    expect(next.opened, isEmpty);
    await sent;
    expect(next.opened, isEmpty);
    expect(api.updates.single['media_id'], 11);
  });

  test('an ended party clears itself and says so', () async {
    final (session, api) = await open();
    final notices = <String>[];
    session.notices.listen(notices.add);

    api.polls.last.completeError(DioException(
      requestOptions: RequestOptions(path: '/api/watch-parties/ABC234'),
      response: Response(
        requestOptions: RequestOptions(path: '/api/watch-parties/ABC234'),
        statusCode: 404,
      ),
    ));
    await _settle();

    expect(session.isClosed, isTrue);
    expect(WatchPartySession.active.value, isNull);
    expect(notices, ['La séance est terminée.']);
  });
}
