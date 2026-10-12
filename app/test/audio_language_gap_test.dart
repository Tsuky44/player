import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/series_track_preferences.dart';
import 'package:onyx/screens/player/hooks/use_episode_navigation.dart';
import 'package:onyx/screens/player/playback/audio_language_gap.dart';
import 'package:onyx/screens/player/playback/series_track_memory.dart';
import 'package:onyx/screens/player/widgets/language_gap_overlay.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/playback_preferences_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SeriesServer extends ApiClient {
  final List<Map<String, Object>> writes = [];

  @override
  Future<SeriesTrackPreferences> updateSeriesTrackPreferences(
    int episodeId,
    Map<String, Object> fields,
  ) async {
    writes.add(fields);
    return SeriesTrackPreferences.fromJson(Map<String, dynamic>.from(fields));
  }
}

/// Attendre sa langue (ADR-0057) : un anime suivi en VF dont l'épisode suivant
/// n'existe encore qu'en japonais ne s'enchaîne pas sans qu'on l'ait demandé.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  AudioLanguageGap? gap(String? heard, String? wanted, List<String> next) =>
      AudioLanguageGap.between(heard: heard, wanted: wanted, next: next);

  group('ce qui manque à l\'épisode suivant', () {
    test('la langue qu\'on écoute n\'y est pas : la question se pose', () {
      final found = gap('fr', null, ['ja']);
      expect(found?.wanted, 'fr');
      expect(found?.offered, 'ja');
    });

    test('elle y est : rien à demander', () {
      expect(gap('fr', null, ['ja', 'fr']), isNull);
    });

    test('qui a accepté de continuer en japonais n\'est pas réinterrogé', () {
      // Le français reste la langue héritée, le japonais celle qu'on entend.
      expect(gap('ja', 'fr', ['ja']), isNull);
    });

    test('la langue héritée revient sans question dès qu\'un épisode l\'a', () {
      expect(gap('ja', 'fr', ['fr']), isNull);
    });

    test('ni l\'une ni l\'autre : on nomme la langue qu\'on suit', () {
      final found = gap('ja', 'fr', ['en', 'de']);
      expect(found?.wanted, 'fr');
      expect(found?.offered, 'en');
    });

    test('un serveur qui ne connaît pas les langues n\'affirme rien', () {
      expect(gap('fr', null, const []), isNull);
      expect(gap(null, null, ['ja']), isNull);
    });
  });

  group('ce qui manque à l\'épisode qu\'on lance', () {
    AudioLanguageGap? missing(String? wanted, List<String> available) =>
        AudioLanguageGap.missing(
            wanted: wanted, heard: 'ja', available: available);

    test('la langue par défaut n\'y est pas : la question se pose', () {
      final found = missing('fr', ['ja', 'en']);
      expect(found?.wanted, 'fr');
      expect(found?.offered, 'ja');
    });

    test('elle y est, ou aucune langue n\'est suivie : rien à demander', () {
      expect(missing('fr', ['ja', 'fr']), isNull);
      expect(missing(null, ['ja']), isNull);
      expect(missing('fr', const []), isNull);
    });
  });

  group('l\'enchaînement retenu', () {
    EpisodeNavigationController controller() {
      final nav = EpisodeNavigationController(
        apiClient: ApiClient(),
        episodeId: 1,
      );
      addTearDown(nav.dispose);
      return nav;
    }

    const missingFrench = AudioLanguageGap(wanted: 'fr', offered: 'ja');

    test('sans écart, rien ne retient l\'épisode suivant', () {
      final nav = controller();
      expect(nav.holdForLanguageGap(null, automatic: true), isFalse);
      expect(nav.showEndCard, isFalse);
    });

    test('un écart lève la carte, qui tient l\'écran comme une carte de fin',
        () {
      final nav = controller();
      expect(nav.holdForLanguageGap(missingFrench, automatic: true), isTrue);
      expect(nav.showLanguageGapCard, isTrue);
      expect(nav.showEndCard, isTrue);
      expect(nav.languageGap?.wanted, 'fr');
    });

    test('après un « non », plus rien n\'enchaîne tout seul', () {
      final nav = controller();
      nav.holdForLanguageGap(missingFrench, automatic: true);
      nav.declineLanguageGap();

      expect(nav.showEndCard, isFalse);
      expect(nav.languageGapDeclined, isTrue);
      expect(nav.holdForLanguageGap(missingFrench, automatic: true), isTrue);
      expect(nav.showLanguageGapCard, isFalse,
          reason: 'le compte à rebours ne repose pas la question');
    });

    test('redemander la suite à la main repose la question', () {
      final nav = controller();
      nav.holdForLanguageGap(missingFrench, automatic: true);
      nav.declineLanguageGap();

      expect(nav.holdForLanguageGap(missingFrench, automatic: false), isTrue);
      expect(nav.showLanguageGapCard, isTrue);
    });
  });

  group('la langue attendue', () {
    Media episode(int id) => Media.fromJson({
          'id': id,
          'type': 'episode',
          'title': 'Épisode $id',
          'parent_id': 10,
        });

    test('part vers le compte seule, sans toucher aux pistes choisies',
        () async {
      final server = _SeriesServer();
      final memory = SeriesTrackMemory.forMedia(server, episode(1))!;
      memory.rememberAwaitedAudio('fr');
      await memory.settled;

      expect(server.writes, [
        {'await_audio_lang': 'fr'}
      ]);
    });

    test('cesser d\'attendre envoie une langue vide', () async {
      final server = _SeriesServer();
      final memory = SeriesTrackMemory.forMedia(server, episode(1))!;
      memory.rememberAwaitedAudio('');
      await memory.settled;

      expect(server.writes.single, {'await_audio_lang': ''});
    });

    test('« continuer » se retient par saison, et s\'oublie', () async {
      final server = _SeriesServer();
      final memory = SeriesTrackMemory.forMedia(server, episode(1))!;
      expect(await memory.acceptedWithout('fr'), isFalse);

      await memory.acceptOtherLanguage('fr');
      final later = SeriesTrackMemory.forMedia(server, episode(2))!;
      expect(await later.acceptedWithout('fr'), isTrue);
      expect(await later.acceptedWithout('en'), isFalse);

      await later.acceptOtherLanguage(null);
      expect(await memory.acceptedWithout('fr'), isFalse);
    });

    test('elle ne compte pas comme un réglage à appliquer à un épisode', () {
      final prefs =
          SeriesTrackPreferences.fromJson({'await_audio_lang': 'fr'});
      expect(prefs.awaitAudioLang, 'fr');
      expect(prefs.isEmpty, isTrue);
      expect(prefs.withAudioLang('ja').awaitAudioLang, 'fr');
    });
  });

  // Les mêmes cas que TestAudioLangCodeMatchesTheAppRule côté serveur
  // (server/indexer/audio_langs_test.go) : le code que le lecteur retient doit
  // retrouver les langues que le serveur inscrit pour chaque épisode.
  test('le code de langue est le même que celui du serveur', () {
    const cases = <String, String?>{
      'fre': 'fr', 'fra': 'fr', 'FR': 'fr', 'French': 'fr', 'fr-FR': 'fr',
      'jpn': 'ja', 'ja': 'ja', 'eng': 'en', 'ger': 'de', 'deu': 'de',
      'chi': 'zh', 'zho': 'zh', 'kor': 'ko', 'pol': 'po',
      '': null, 'und': null, ' ': null, 'auto': null, 'no': null,
    };
    cases.forEach((tag, code) {
      expect(PlaybackPreferencesStorage.normalizeLangCode(tag), code,
          reason: 'étiquette « $tag »');
    });
  });

  testWidgets('la carte nomme les deux langues et rend chaque réponse',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final answers = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [
        LanguageGapOverlay(
          gap: const AudioLanguageGap(wanted: 'fr', offered: 'ja'),
          onContinue: () => answers.add('continuer'),
          onWait: () => answers.add('attendre'),
          onDismiss: () => answers.add('fermer'),
        ),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(
        find.text('L’épisode suivant n’est pas disponible en français.'),
        findsOneWidget);
    await tester.tap(find.text('Continuer en japonais'));
    await tester.tap(find.text('Attendre la version en français'));
    expect(answers, ['continuer', 'attendre']);
  });

  testWidgets('au lancement, la carte parle de l\'épisode en cours',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [
        LanguageGapOverlay(
          gap: const AudioLanguageGap(wanted: 'fr', offered: 'ja'),
          atLaunch: true,
          onContinue: () {},
          onWait: () {},
          onDismiss: () {},
        ),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Cet épisode n’est pas disponible en français.'),
        findsOneWidget);
    expect(find.text('Continuer en japonais'), findsOneWidget);
  });
}
