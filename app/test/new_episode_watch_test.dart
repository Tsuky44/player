import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/l10n/app_language.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/client_identity.dart';
import 'package:onyx/services/new_episodes/new_episode_watch.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_doubles.dart';

/// La veille des nouveaux épisodes (ADR-0059) : l'appareil fait le tour de
/// ses serveurs et n'annonce chaque épisode qu'une fois.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const home = ServerAccount(
      id: 'home', url: 'http://maison.test', username: 'mathis');
  const friend = ServerAccount(
      id: 'friend',
      url: 'http://paul.test',
      username: 'mathis',
      label: 'Chez Paul');

  HomeMediaItem episode({
    required int showId,
    required int number,
    bool isNew = true,
    int id = 100,
  }) {
    return HomeMediaItem.fromJson({
      'id': id,
      'type': 'episode',
      'title': 'Épisode $number',
      'duration': 2400,
      'show_id': showId,
      'show_title': 'Série $showId',
      'season_number': 1,
      'episode_number': number,
      'created_at': '2026-10-10T10:00:00Z',
      if (isNew) 'has_new_episode': true,
    });
  }

  late Map<String, List<HomeMediaItem>> rows;
  late Set<String> unreachable;
  late List<ServerAccount> accounts;

  NewEpisodeWatch watch() => NewEpisodeWatch(
        accounts: () => accounts,
        fetch: (account) async {
          if (unreachable.contains(account.id)) throw StateError('muet');
          return rows[account.id] ?? const [];
        },
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    rows = {};
    unreachable = {};
    accounts = [home, friend];
  });
  tearDown(AppLanguage.resetForTest);

  test('le premier regard sur un serveur est un état des lieux, sans annonce',
      () async {
    rows['home'] = [episode(showId: 7, number: 4)];

    expect(await watch().check(), isEmpty,
        reason: 'activer les notifications ne doit pas annoncer d’un coup '
            'ce que l’accueil affiche déjà depuis des jours');
  });

  test('un épisode sorti depuis le dernier passage est annoncé, une seule fois',
      () async {
    rows['home'] = [episode(showId: 7, number: 4)];
    await watch().check();

    rows['home'] = [episode(showId: 7, number: 5)];
    final alerts = await watch().check();

    expect(alerts, hasLength(1));
    expect(alerts.single.showTitle, 'Série 7');
    expect(alerts.single.episode, 5);
    expect(await watch().check(), isEmpty,
        reason: 'le passage suivant retrouve le même épisode : déjà dit');
  });

  test('seul ce que le serveur marque « nouvel épisode » est annoncé',
      () async {
    await watch().check();

    rows['home'] = [episode(showId: 7, number: 5, isNew: false)];

    expect(await watch().check(), isEmpty,
        reason: 'c’est le serveur qui décide de ce qui est une sortie');
  });

  test('chaque serveur de l’appareil est interrogé, pas seulement l’actif',
      () async {
    await watch().check();

    rows['home'] = [episode(showId: 7, number: 5)];
    rows['friend'] = [episode(showId: 7, number: 9)];
    final alerts = await watch().check();

    expect(alerts.map((a) => a.accountId), unorderedEquals(['home', 'friend']),
        reason: 'la série 7 de l’un n’est pas la série 7 de l’autre '
            '(ADR-0013) : les deux sont annoncées');
    expect(alerts.firstWhere((a) => a.accountId == 'friend').serverName,
        'Chez Paul');
  });

  test('le serveur à l’écran est enregistré sans rien annoncer', () async {
    await watch().check();

    rows['home'] = [episode(showId: 7, number: 5)];
    expect(await watch().check(quiet: {'home'}), isEmpty,
        reason: 'la pastille de l’accueil le dit déjà');
    expect(await watch().check(), isEmpty,
        reason: 'vu à l’écran, il ne sera pas annoncé plus tard non plus');
  });

  test('un serveur muet n’empêche pas les autres, et se rattrape ensuite',
      () async {
    await watch().check();

    unreachable = {'home'};
    rows['home'] = [episode(showId: 7, number: 5)];
    rows['friend'] = [episode(showId: 3, number: 2)];
    final first = await watch().check();
    expect(first.map((a) => a.accountId), ['friend']);

    unreachable = {};
    final second = await watch().check();
    expect(second.map((a) => a.accountId), ['home'],
        reason: 'un serveur local injoignable en 4G annonce en rentrant');
  });

  test('un serveur muet au premier passage garde son état des lieux à faire',
      () async {
    unreachable = {'home'};
    await watch().check();

    unreachable = {};
    rows['home'] = [episode(showId: 7, number: 5)];
    expect(await watch().check(), isEmpty,
        reason: 'on n’a jamais vu ce serveur : rien n’y est « nouveau »');
  });

  test('un fichier remplacé ne réannonce pas le même épisode', () async {
    await watch().check();
    rows['home'] = [episode(showId: 7, number: 5, id: 100)];
    await watch().check();

    rows['home'] = [episode(showId: 7, number: 5, id: 250)];
    expect(await watch().check(), isEmpty,
        reason: 'une meilleure copie change l’identifiant du fichier, pas '
            'le numéro de l’épisode');
  });

  test('un compte retiré de l’appareil emporte ce qu’on avait retenu de lui',
      () async {
    rows['friend'] = [episode(showId: 3, number: 2)];
    await watch().check();

    accounts = [home];
    await watch().check();
    accounts = [home, friend];

    expect(await watch().check(), isEmpty,
        reason: 'revenu au carnet, le compte repart d’un état des lieux');
  });

  test('le texte nomme le serveur seulement quand il y en a plusieurs', () {
    final alert = NewEpisodeAlert.fromItem(
        friend, episode(showId: 7, number: 5))!;

    expect(alert.body(nameServer: false), 'Nouvel épisode · S1 · Épisode 5');
    expect(alert.body(nameServer: true),
        'Nouvel épisode · S1 · Épisode 5 — sur Chez Paul');
  });

  test('la notification porte de quoi rouvrir la série sur son serveur', () {
    final alert = NewEpisodeAlert.fromItem(
        friend, episode(showId: 7, number: 5))!;
    final reread = NewEpisodeAlert.fromPayload(alert.toPayload())!;

    expect(reread.accountId, 'friend');
    expect(reread.showId, 7);
    expect(reread.showTitle, 'Série 7');
    expect(reread.notificationId, alert.notificationId,
        reason: 'le même épisode réaffiché remplace sa notification');
    expect(NewEpisodeAlert.fromPayload('pas du json'), isNull);
    expect(NewEpisodeAlert.fromPayload(null), isNull);
  });

  test('« À reprendre » d’un compte se lit avec son jeton, sans identité',
      () async {
    late RequestOptions seen;
    final api = ApiClient(registry: Registry())
      ..clientFactory = (options) => Dio(options)
        ..httpClientAdapter = Adapter((request) {
          seen = request;
          return ResponseBody.fromString(
            jsonEncode({
              'continue_watching': [
                {
                  'id': 100,
                  'type': 'episode',
                  'title': 'Épisode 5',
                  'duration': 2400,
                  'show_id': 7,
                  'show_title': 'Série 7',
                  'created_at': '2026-10-10T10:00:00Z',
                  'has_new_episode': true,
                },
              ],
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        });

    final items = await api.continueWatchingOf('b');

    expect(items.single.hasNewEpisode, isTrue);
    expect(seen.uri.toString(), 'http://b.test/api/home');
    expect(seen.headers['Authorization'], 'Bearer token-b',
        reason: 'le jeton d’un serveur n’est jamais présenté à un autre');
    expect(seen.headers.containsKey(ClientIdentity.deviceHeader), isFalse,
        reason: 'la tâche de fond ne connaît pas le nom de l’appareil : en '
            'envoyer un renommerait la session côté serveur');
  });
}
