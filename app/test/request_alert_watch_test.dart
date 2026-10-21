import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/l10n/app_language.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/models/request_feed.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/new_episodes/new_episode_alerts.dart';
import 'package:onyx/services/notifications/notification_poster.dart';
import 'package:onyx/services/request_alerts/request_alert_watch.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_doubles.dart';

/// La veille des nouvelles demandes (ADR-0077) : l'appareil d'un
/// administrateur relève le flux d'OnyxHub et n'annonce chaque demande
/// qu'une fois.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const home =
      ServerAccount(id: 'home', url: 'http://maison.test', username: 'mathis');
  const friend = ServerAccount(
      id: 'friend',
      url: 'http://paul.test',
      username: 'mathis',
      label: 'Chez Paul');

  RequestFeedEntry got(int id) => RequestFeedEntry(
        id: id,
        mediaType: RequestMediaType.tv,
        tmdbId: 1399,
        title: 'Game of Thrones',
        posterPath: null,
        seasons: const [1, 2],
        requester: 'lea',
        requestedAt: null,
      );

  /// Ce que chaque serveur rend : null pour « pas de flux », absent pour muet.
  late Map<String, RequestFeed?> feeds;
  late Map<String, int?> asked;
  late List<ServerAccount> accounts;

  RequestAlertWatch watch() => RequestAlertWatch(
        accounts: () => accounts,
        fetch: (account, after) async {
          asked[account.id] = after;
          if (!feeds.containsKey(account.id)) throw StateError('muet');
          return feeds[account.id];
        },
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    feeds = {};
    asked = {};
    accounts = [home, friend];
  });
  tearDown(AppLanguage.resetForTest);

  test('le premier passage pose le curseur sans rien annoncer', () async {
    feeds['home'] = RequestFeed(cursor: 40, requests: [got(40)]);

    expect(await watch().check(), isEmpty,
        reason: 'activer les notifications n’annonce pas l’historique');
    expect(asked['home'], isNull);

    feeds['home'] = const RequestFeed(cursor: 40, requests: []);
    await watch().check();
    expect(asked['home'], 40, reason: 'le curseur rendu est renvoyé');
  });

  test('une demande faite depuis le dernier passage est annoncée une fois',
      () async {
    feeds['home'] = const RequestFeed(cursor: 39, requests: []);
    await watch().check();

    feeds['home'] = RequestFeed(cursor: 41, requests: [got(40)]);
    final alerts = await watch().check();
    expect(alerts.single.entry.id, 40);

    expect(asked['home'], 39);
    feeds['home'] = const RequestFeed(cursor: 41, requests: []);
    expect(await watch().check(), isEmpty);
    expect(asked['home'], 41);
  });

  test('un serveur muet garde son curseur et rattrape au passage suivant',
      () async {
    feeds['home'] = const RequestFeed(cursor: 39, requests: []);
    await watch().check();

    feeds.remove('home');
    expect(await watch().check(), isEmpty);

    feeds['home'] = RequestFeed(cursor: 40, requests: [got(40)]);
    expect(await watch().check(), hasLength(1));
    expect(asked['home'], 39);
  });

  test('un compte qui n’a plus de flux repart d’un premier passage', () async {
    feeds['home'] = const RequestFeed(cursor: 39, requests: []);
    await watch().check();

    feeds['home'] = null;
    await watch().check();

    feeds['home'] = RequestFeed(cursor: 45, requests: [got(44)]);
    expect(await watch().check(), isEmpty,
        reason: 'redevenu administrateur, on n’apprend pas d’un coup tout '
            'ce qui a été demandé entre-temps');
    expect(asked['home'], isNull);
  });

  test('la notification dit qui, quoi et quelles saisons', () {
    final alert = NewRequestAlert(
        accountId: 'home', serverName: 'Maison', entry: got(40));
    expect(alert.title, 'Nouvelle demande de lea');
    expect(alert.body(nameServer: false), 'Game of Thrones · Saisons 1, 2');
    expect(alert.body(nameServer: true),
        'Game of Thrones · Saisons 1, 2 — sur Maison');

    final movie = NewRequestAlert(
      accountId: 'home',
      serverName: 'Maison',
      entry: RequestFeedEntry.fromJson({
        'id': 38,
        'mediaType': 'movie',
        'tmdbId': 603,
        'title': 'Matrix',
        'seasons': <int>[],
        'requester': 'hugo',
      }),
    );
    expect(movie.body(nameServer: false), 'Matrix · Film');
    expect(movie.notificationId, isNot(alert.notificationId));
  });

  test(
      'le flux se lit avec le jeton du compte, et un refus veut dire « pas '
      'de flux »', () async {
    late RequestOptions seen;
    var status = 200;
    final api = ApiClient(registry: Registry())
      ..clientFactory = (options) => Dio(options)
        ..httpClientAdapter = Adapter((request) {
          seen = request;
          return ResponseBody.fromString(
            jsonEncode(status == 200
                ? {'cursor': 42, 'requests': []}
                : {'error': 'refusé'}),
            status,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        });

    final feed = await api.requestFeedOf('b', after: 41);
    expect(feed?.cursor, 42);
    expect(seen.uri.toString(), 'http://b.test/api/requests/feed?after=41');
    expect(seen.headers['Authorization'], 'Bearer token-b');

    status = 403;
    expect(await api.requestFeedOf('b', after: 41), isNull,
        reason: 'un compte qui n’administre pas ce serveur n’a pas de flux');
    status = 502;
    expect(api.requestFeedOf('b', after: 41), throwsA(isA<DioException>()),
        reason: 'OnyxHub muet : le curseur doit rester pour rattraper');
  });

  test('la tâche de fond ne refait les épisodes qu’une fois par heure',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final t0 = DateTime(2026, 10, 21, 9);

    expect(await NewEpisodeAlerts.episodesDue(prefs, t0), isTrue);
    expect(
        await NewEpisodeAlerts.episodesDue(
            prefs, t0.add(NewEpisodeAlerts.interval)),
        isFalse,
        reason: 'les demandes passent au quart d’heure, pas `/api/home`');
    expect(
        await NewEpisodeAlerts.episodesDue(
            prefs, t0.add(NewEpisodeAlerts.episodeInterval)),
        isTrue);
  });

  test(
      'l’affiche de la notification vient de TMDB, et son absence n’empêche '
      'pas la notification', () async {
    expect(got(40).posterUrl, isNull);
    final entry = RequestFeedEntry.fromJson(
        {'id': 38, 'mediaType': 'movie', 'posterPath': '/matrix.jpg'});
    expect(entry.posterUrl, 'https://image.tmdb.org/t/p/w342/matrix.jpg');

    late String type;
    var status = 200;
    final dio = Dio()
      ..httpClientAdapter = Adapter((request) => ResponseBody.fromBytes(
            [0xff, 0xd8, 0xff],
            status,
            headers: {
              Headers.contentTypeHeader: [type],
            },
          ));

    type = 'image/jpeg';
    final poster = await NotificationPoster.load(entry.posterUrl, dio: dio);
    expect(poster?.bytes, [0xff, 0xd8, 0xff]);

    expect(await NotificationPoster.load(null, dio: dio), isNull);
    type = 'text/html';
    expect(await NotificationPoster.load(entry.posterUrl, dio: dio), isNull,
        reason: 'une page d’erreur n’est pas une affiche');
    type = 'image/jpeg';
    status = 404;
    expect(await NotificationPoster.load(entry.posterUrl, dio: dio), isNull,
        reason: 'sans affiche, la notification part quand même');
  });
}
