import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/playback_preferences.dart';
import 'package:onyx/models/still_watching_settings.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/playback_preferences_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Le compte tel que le serveur le tient, en mémoire. Les mises à jour sont
/// partielles, comme sur la vraie route.
class _AccountServer extends ApiClient {
  bool autoSkipIntro = false;
  String lang = '';

  /// Null : un serveur d'avant « Vous regardez encore ? », qui n'en dit rien.
  StillWatchingSettings? stillWatching = StillWatchingSettings.defaults;
  bool saved = false;
  bool offline = false;
  final List<Map<String, Object>> writes = [];

  AccountPlaybackPreferences get _snapshot => AccountPlaybackPreferences(
        autoSkipIntro: autoSkipIntro,
        defaultAudioLang: lang.isEmpty ? null : lang,
        stillWatching: stillWatching,
        isSaved: saved,
      );

  @override
  Future<AccountPlaybackPreferences> getPlaybackPreferences() async {
    if (offline) throw StateError('offline');
    return _snapshot;
  }

  @override
  Future<AccountPlaybackPreferences> updatePlaybackPreferences(
    Map<String, Object> fields,
  ) async {
    if (offline) throw StateError('offline');
    writes.add(fields);
    if (fields['auto_skip_intro'] case final bool value) autoSkipIntro = value;
    if (fields['default_audio_lang'] case final String value) lang = value;
    if (stillWatching != null && fields['still_watching_enabled'] is bool) {
      stillWatching = StillWatchingSettings.fromJson(
        Map<String, dynamic>.from(fields),
      );
    }
    saved = true;
    return _snapshot;
  }
}

/// Les réglages de lecture suivent le compte (ADR-0043) : un appareil qui se
/// connecte prend ceux du compte, et ce qu'on y change part vers le compte —
/// y compris ce qui a été changé sans réseau.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final storage = PlaybackPreferencesStorage();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlaybackPreferencesStorage.resetForTest();
  });

  test('a device signing in takes the preferences of the account', () async {
    final server = _AccountServer()
      ..autoSkipIntro = true
      ..lang = 'en'
      ..saved = true;

    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');

    expect(PlaybackPreferencesStorage.autoSkipIntro, isTrue);
    expect(await storage.loadDefaultAudioLang(), 'en');
    expect(PlaybackPreferencesStorage.accountRevision.value, 1);
    expect(server.writes, isEmpty);
  });

  test('an account with nothing saved is seeded from the first device',
      () async {
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    await storage.saveDefaultAudioLang('fr');
    final server = _AccountServer();

    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');

    expect(server.autoSkipIntro, isTrue);
    expect(server.lang, 'fr');
    expect(PlaybackPreferencesStorage.autoSkipIntro, isTrue);
    expect(await storage.loadDefaultAudioLang(), 'fr');
  });

  test('a change on this device reaches the account, field by field',
      () async {
    final server = _AccountServer()
      ..lang = 'en'
      ..saved = true;
    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');

    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    await pumpEventQueue();

    expect(server.autoSkipIntro, isTrue);
    expect(server.writes.single, {'auto_skip_intro': true});
    expect(server.lang, 'en');
  });

  test('clearing the audio language clears it on the account', () async {
    final server = _AccountServer()
      ..lang = 'en'
      ..saved = true;
    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');

    await storage.saveDefaultAudioLang(null);
    await pumpEventQueue();

    expect(server.lang, '');
  });

  test('a change made offline wins over the account at the next sync',
      () async {
    final server = _AccountServer()
      ..lang = 'en'
      ..saved = true;
    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');

    server.offline = true;
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    await pumpEventQueue();
    expect(server.autoSkipIntro, isFalse);

    // Entre-temps, un autre appareil a changé la langue : elle n'est pas en
    // attente ici, donc c'est celle du compte qui s'applique.
    server
      ..offline = false
      ..lang = 'ja';
    await PlaybackPreferencesStorage.syncWithAccount();

    expect(server.autoSkipIntro, isTrue);
    expect(server.lang, 'ja');
    expect(PlaybackPreferencesStorage.autoSkipIntro, isTrue);
    expect(await storage.loadDefaultAudioLang(), 'ja');
  });

  test('a change pending for one account never reaches another', () async {
    final first = _AccountServer()..saved = true;
    await PlaybackPreferencesStorage.bindAccount(first, 'a|1');
    first.offline = true;
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    await pumpEventQueue();

    final second = _AccountServer()
      ..lang = 'de'
      ..saved = true;
    await PlaybackPreferencesStorage.bindAccount(second, 'a|2');

    expect(second.writes, isEmpty);
    expect(second.autoSkipIntro, isFalse);
    expect(PlaybackPreferencesStorage.autoSkipIntro, isFalse);
    expect(await storage.loadDefaultAudioLang(), 'de');
  });

  test('signed out, a change stays on the device', () async {
    final server = _AccountServer()..saved = true;
    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');
    PlaybackPreferencesStorage.unbindAccount();

    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    await pumpEventQueue();

    expect(server.writes, isEmpty);
    expect(PlaybackPreferencesStorage.autoSkipIntro, isTrue);
  });

  test('"still watching" follows the account like the other preferences',
      () async {
    const night = StillWatchingSettings(
      episodes: 2,
      fromMinute: 22 * 60,
      untilMinute: 6 * 60,
    );
    final server = _AccountServer()
      ..stillWatching = night
      ..saved = true;

    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');
    expect(PlaybackPreferencesStorage.stillWatching, night);

    const off = StillWatchingSettings(enabled: false, episodes: 2);
    await PlaybackPreferencesStorage.setStillWatching(off);
    await pumpEventQueue();

    expect(server.stillWatching, off);
    // Les quatre champs partent ensemble : les bornes ne se valident qu'à deux.
    expect(server.writes.single, {
      'still_watching_enabled': false,
      'still_watching_episodes': 2,
      'still_watching_from': -1,
      'still_watching_until': -1,
    });
  });

  test('a server too old to know "still watching" leaves it to the device',
      () async {
    const mine = StillWatchingSettings(episodes: 5);
    await PlaybackPreferencesStorage.setStillWatching(mine);
    final server = _AccountServer()
      ..stillWatching = null
      ..autoSkipIntro = true
      ..saved = true;

    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');

    expect(PlaybackPreferencesStorage.autoSkipIntro, isTrue);
    expect(PlaybackPreferencesStorage.stillWatching, mine);
  });

  test('"still watching" survives a restart of the app', () async {
    const mine = StillWatchingSettings(
      episodes: 4,
      fromMinute: 23 * 60,
      untilMinute: 5 * 60,
    );
    await PlaybackPreferencesStorage.setStillWatching(mine);

    PlaybackPreferencesStorage.resetForTest();
    await PlaybackPreferencesStorage.initialize();

    expect(PlaybackPreferencesStorage.stillWatching, mine);
  });

  test('an unreachable server leaves the local preferences in place',
      () async {
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    final server = _AccountServer()..offline = true;

    await PlaybackPreferencesStorage.bindAccount(server, 'a|1');

    expect(PlaybackPreferencesStorage.autoSkipIntro, isTrue);
    expect(PlaybackPreferencesStorage.accountRevision.value, 0);
  });
}
