import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/series_track_preferences.dart';
import 'package:onyx/screens/player/playback/series_track_memory.dart';
import 'package:onyx/screens/player/player_playback_preferences.dart';
import 'package:onyx/services/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Le compte tel que le serveur le tient, en mémoire : une seule série, des
/// mises à jour partielles comme sur la vraie route.
class _SeriesServer extends ApiClient {
  String audioLang = '';
  Map<String, Object>? subtitle;
  bool offline = false;
  final List<int> episodesAsked = [];
  final List<Map<String, Object>> writes = [];

  SeriesTrackPreferences get _snapshot => SeriesTrackPreferences.fromJson({
        'audio_lang': audioLang,
        'subtitle': subtitle ?? {'mode': ''},
      });

  @override
  Future<SeriesTrackPreferences> getSeriesTrackPreferences(
      int episodeId) async {
    if (offline) throw StateError('offline');
    episodesAsked.add(episodeId);
    return _snapshot;
  }

  @override
  Future<SeriesTrackPreferences> updateSeriesTrackPreferences(
    int episodeId,
    Map<String, Object> fields,
  ) async {
    if (offline) throw StateError('offline');
    writes.add(fields);
    if (fields['audio_lang'] case final String value) audioLang = value;
    if (fields['subtitle'] case final Map<String, Object> value) {
      subtitle = value;
    }
    return _snapshot;
  }
}

Media _episode(int id, {int season = 10}) => Media.fromJson({
      'id': id,
      'type': 'episode',
      'title': 'Épisode $id',
      'parent_id': season,
    });

MediaAudioTrack _audio(int index, String language, {bool isDefault = false}) =>
    MediaAudioTrack.fromJson({
      'index': index,
      'typed_index': index,
      'codec': 'aac',
      'language': language,
      'channels': 2,
      'default': isDefault,
    });

MediaSubtitleTrack _sub(String lang, {String language = 'fr', bool forced = false}) =>
    MediaSubtitleTrack(
        lang: lang, name: lang, language: language, forced: forced);

/// La langue audio et le sous-titre choisis dans un épisode valent pour toute
/// la série, sur tous les appareils du compte et d'une séance à l'autre
/// (ADR-0044).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  const frenchFull = SeriesSubtitleChoice(language: 'fr', key: 'fr');

  test('un choix fait dans un épisode se retrouve dans un autre, sur un autre appareil',
      () async {
    final server = _SeriesServer();
    final phone = SeriesTrackMemory.forMedia(server, _episode(1))!;
    phone.rememberAudio('en');
    phone.rememberSubtitle(frenchFull);
    await phone.settled;

    // Un autre appareil n'a aucune copie locale : tout vient du compte.
    SharedPreferences.setMockInitialValues({});
    final tv = SeriesTrackMemory.forMedia(server, _episode(2))!;
    final stored = await tv.load();

    expect(stored?.audioLang, 'en');
    expect(stored?.subtitle?.language, 'fr');
    expect(stored?.subtitle?.forced, isFalse);
    expect(server.episodesAsked, [2]);
  });

  test('« désactivés » est un choix qui suit lui aussi', () async {
    final server = _SeriesServer();
    final memory = SeriesTrackMemory.forMedia(server, _episode(1))!;
    memory.rememberSubtitle(frenchFull);
    memory.rememberSubtitle(const SeriesSubtitleChoice.off());
    await memory.settled;

    final stored = await SeriesTrackMemory.forMedia(server, _episode(2))!.load();
    expect(stored?.subtitle?.off, isTrue);
    expect(PlayerPlaybackPreferences.fromSeries(stored!).subtitlesOff, isTrue);
  });

  test('une série sans choix laisse le lecteur à ses réglages par défaut',
      () async {
    final memory = SeriesTrackMemory.forMedia(_SeriesServer(), _episode(1))!;
    expect(await memory.load(), isNull);
  });

  test('un film ne retient rien', () {
    final movie = Media.fromJson({'id': 5, 'type': 'movie', 'title': 'Film'});
    expect(SeriesTrackMemory.forMedia(_SeriesServer(), movie), isNull);
  });

  test('un choix fait sans réseau sert tout de suite, puis part vers le compte',
      () async {
    final server = _SeriesServer()..offline = true;
    final memory = SeriesTrackMemory.forMedia(server, _episode(1))!;
    memory.rememberAudio('en');
    await memory.settled;

    // Toujours hors ligne : l'épisode suivant s'ouvre avec la copie locale.
    final offline = await SeriesTrackMemory.forMedia(server, _episode(2))!.load();
    expect(offline?.audioLang, 'en');
    expect(server.writes, isEmpty);

    // Le réseau revient : ce qui attendait part avant de lire le compte, qui
    // ne doit pas recouvrir le choix avec son ancienne valeur.
    server
      ..offline = false
      ..audioLang = 'fr';
    final online = await SeriesTrackMemory.forMedia(server, _episode(3))!.load();
    expect(online?.audioLang, 'en');
    expect(server.audioLang, 'en');
    expect(server.writes, [
      {'audio_lang': 'en'}
    ]);
  });

  test('changer de sous-titre n\'envoie pas la langue audio', () async {
    final server = _SeriesServer()..audioLang = 'en';
    final memory = SeriesTrackMemory.forMedia(server, _episode(1))!;
    memory.rememberSubtitle(frenchFull);
    await memory.settled;

    expect(server.writes.single.keys, ['subtitle']);
    expect(server.audioLang, 'en');
  });

  group('appliqué à un épisode', () {
    final stored = PlayerPlaybackPreferences.fromSeries(
      const SeriesTrackPreferences(audioLang: 'en', subtitle: frenchFull),
    );

    test('la langue audio se retrouve quel que soit l\'ordre des pistes', () {
      expect(
          stored.audioIndexIn([_audio(0, 'fre', isDefault: true), _audio(1, 'eng')]),
          1);
      expect(stored.audioIndexIn([_audio(0, 'eng'), _audio(1, 'fre')]), 0);
    });

    test('sans la langue voulue, le réglage du compte puis la piste du fichier',
        () {
      final tracks = [_audio(0, 'jpn', isDefault: true), _audio(1, 'fre')];
      expect(stored.audioIndexIn(tracks, defaultLang: 'fr'), 1);
      expect(stored.audioIndexIn(tracks), 0);
    });

    test('à langue égale, le rang de l\'épisode précédent départage', () {
      const carried = PlayerPlaybackPreferences(
          audioIndex: 1, audioLang: 'en', subtitlesOff: true);
      expect(
          carried.audioIndexIn([_audio(0, 'eng', isDefault: true), _audio(1, 'eng')]),
          1);
      // Le rang ne désigne plus la même langue : la langue l'emporte.
      expect(carried.audioIndexIn([_audio(0, 'eng'), _audio(1, 'fre')]), 0);
    });

    test('le sous-titre complet reste complet, au plus proche sinon', () {
      final wanted = stored.subtitle!;
      expect(
          wanted.matchIn([_sub('fr', forced: true), _sub('fr2')])?.lang, 'fr2');
      expect(wanted.matchIn([_sub('en', language: 'en')]), isNull);
    });
  });
}
