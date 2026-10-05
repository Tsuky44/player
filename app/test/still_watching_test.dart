import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/still_watching_settings.dart';
import 'package:onyx/screens/player/playback/still_watching.dart';
import 'package:onyx/screens/player/widgets/still_watching_prompt.dart';
import 'package:onyx/screens/settings/pages/playback_still_watching_group.dart';
import 'package:onyx/services/playback_preferences_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// La règle que ce fichier verrouille (ADR-0045) : le lecteur n'enchaîne pas
/// indéfiniment pour quelqu'un qui dort. Après N épisodes sans le moindre
/// geste, dans la plage horaire choisie, il attend une réponse.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final guard = StillWatching.instance;
  final evening = DateTime(2026, 10, 5, 23, 30);
  final afternoon = DateTime(2026, 10, 5, 15, 0);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlaybackPreferencesStorage.resetForTest();
    guard.resetForTest();
  });
  tearDown(guard.resetForTest);

  group('la plage horaire', () {
    test('toute la journée, la question se pose à toute heure', () {
      const settings = StillWatchingSettings();
      expect(settings.appliesAt(evening), isTrue);
      expect(settings.appliesAt(afternoon), isTrue);
    });

    test('une plage qui passe minuit couvre la nuit, pas l’après-midi', () {
      const night = StillWatchingSettings(fromMinute: 22 * 60, untilMinute: 6 * 60);
      expect(night.appliesAt(DateTime(2026, 10, 5, 22, 0)), isTrue);
      expect(night.appliesAt(evening), isTrue);
      expect(night.appliesAt(DateTime(2026, 10, 6, 5, 59)), isTrue);
      expect(night.appliesAt(DateTime(2026, 10, 6, 6, 0)), isFalse);
      expect(night.appliesAt(afternoon), isFalse);
    });

    test('une plage dans la journée s’arrête à sa borne de fin', () {
      const lunch = StillWatchingSettings(fromMinute: 12 * 60, untilMinute: 14 * 60);
      expect(lunch.appliesAt(DateTime(2026, 10, 5, 13, 0)), isTrue);
      expect(lunch.appliesAt(DateTime(2026, 10, 5, 14, 0)), isFalse);
      expect(lunch.appliesAt(evening), isFalse);
    });

    test('désactivée, elle ne se pose jamais', () {
      const off = StillWatchingSettings(enabled: false);
      expect(off.appliesAt(evening), isFalse);
    });

    test('une valeur incohérente retombe sur ce que le lecteur sait appliquer',
        () {
      final odd = const StillWatchingSettings(
        episodes: 40,
        fromMinute: 600,
        untilMinute: 600,
      ).normalized();
      expect(odd.episodes, StillWatchingSettings.maxEpisodes);
      expect(odd.allDay, isTrue);
    });
  });

  group('le compte des épisodes sans intervention', () {
    test('trois épisodes enchaînés sans geste : le quatrième attend', () {
      guard.retain();

      expect(guard.allowAutoAdvance(now: evening), isTrue);
      expect(guard.allowAutoAdvance(now: evening), isTrue);
      expect(guard.allowAutoAdvance(now: evening), isFalse);
      // La question reste posée tant que personne n'a répondu.
      expect(guard.allowAutoAdvance(now: evening), isFalse);
    });

    testWidgets('une touche remet le compte à zéro', (tester) async {
      guard.retain();
      guard.allowAutoAdvance(now: evening);
      guard.allowAutoAdvance(now: evening);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);

      expect(guard.unattendedEpisodes, 0);
      expect(guard.allowAutoAdvance(now: evening), isTrue);
    });

    testWidgets('un doigt posé n’importe où remet le compte à zéro',
        (tester) async {
      await tester.pumpWidget(const SizedBox.expand());
      guard.retain();
      guard.allowAutoAdvance(now: evening);
      guard.allowAutoAdvance(now: evening);

      await tester.tapAt(const Offset(40, 40));

      expect(guard.unattendedEpisodes, 0);
    });

    testWidgets('le compte suit d’un épisode au suivant et s’arrête avec le lecteur',
        (tester) async {
      await tester.pumpWidget(const SizedBox.expand());
      guard.retain();
      guard.allowAutoAdvance(now: evening);
      guard.retain(); // l'épisode suivant s'ouvre…
      guard.release(); // …avant que le précédent ne se ferme.
      expect(guard.unattendedEpisodes, 1);

      guard.release();
      expect(guard.unattendedEpisodes, 0,
          reason: 'quitter le lecteur clôt la soirée');
    });

    test('hors de la plage, le compte monte sans rien demander', () async {
      await PlaybackPreferencesStorage.setStillWatching(
        const StillWatchingSettings(
          episodes: 2,
          fromMinute: 22 * 60,
          untilMinute: 6 * 60,
        ),
      );
      guard.retain();

      expect(guard.allowAutoAdvance(now: afternoon), isTrue);
      expect(guard.allowAutoAdvance(now: afternoon), isTrue);
      expect(guard.allowAutoAdvance(now: afternoon), isTrue);
      // Le premier générique qui tombe dans la plage arrête celui qui s'est
      // endormi avant qu'elle ne commence.
      expect(guard.allowAutoAdvance(now: evening), isFalse);
    });

    test('désactivée, la lecture enchaîne sans fin', () async {
      await PlaybackPreferencesStorage.setStillWatching(
        const StillWatchingSettings(enabled: false, episodes: 1),
      );
      guard.retain();

      for (var i = 0; i < 12; i++) {
        expect(guard.allowAutoAdvance(now: evening), isTrue);
      }
    });

    test('réglée sur un épisode, la question suit chaque épisode non touché',
        () async {
      await PlaybackPreferencesStorage.setStillWatching(
        const StillWatchingSettings(episodes: 1),
      );
      guard.retain();

      expect(guard.allowAutoAdvance(now: evening), isFalse);
      guard.noteActivity();
      expect(guard.allowAutoAdvance(now: evening), isFalse);
    });
  });

  group('la question à l’écran', () {
    Future<({int Function() continued, int Function() left})> pumpPrompt(
        WidgetTester tester) async {
      var continued = 0;
      var left = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          // Comme dans le lecteur : un nœud tient déjà le focus quand la
          // question arrive.
          body: Focus(
            autofocus: true,
            child: StillWatchingPrompt(
              onContinue: () => continued++,
              onLeave: () => left++,
            ),
          ),
        ),
      ));
      await tester.pump();
      return (continued: () => continued, left: () => left);
    }

    testWidgets('la télécommande arrive sur « Continuer » : OK suffit',
        (tester) async {
      final answers = await pumpPrompt(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(answers.continued(), 1);
      expect(answers.left(), 0);
    });

    testWidgets('la question tient sur un téléphone en paysage', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpPrompt(tester);

      expect(find.text('Vous regardez encore ?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('« Quitter » est l’autre réponse', (tester) async {
      final answers = await pumpPrompt(tester);

      await tester.tap(find.text('Quitter'));

      expect(answers.left(), 1);
      expect(answers.continued(), 0);
    });
  });

  group('le réglage', () {
    Future<List<StillWatchingSettings>> pumpGroup(
      WidgetTester tester,
      StillWatchingSettings value,
    ) async {
      final changes = <StillWatchingSettings>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StillWatchingSettingsGroup(
              value: value,
              onChanged: changes.add,
            ),
          ),
        ),
      ));
      return changes;
    }

    testWidgets('désactivé, il ne montre que son interrupteur', (tester) async {
      await pumpGroup(tester, const StillWatchingSettings(enabled: false));

      expect(find.text('Épisodes sans intervention'), findsNothing);
      expect(find.text('Quand la poser'), findsNothing);
    });

    testWidgets('choisir une plage horaire propose la nuit', (tester) async {
      final changes = await pumpGroup(tester, const StillWatchingSettings());
      expect(find.text('Plage horaire'), findsNothing);

      await tester.tap(find.text('Sur une plage horaire'));

      expect(changes.single.fromMinute, 22 * 60);
      expect(changes.single.untilMinute, 6 * 60);
    });

    testWidgets('la plage affiche ses deux heures', (tester) async {
      await pumpGroup(
        tester,
        const StillWatchingSettings(fromMinute: 22 * 60, untilMinute: 6 * 60),
      );

      expect(find.text('22:00'), findsOneWidget);
      expect(find.text('06:00'), findsOneWidget);
    });

    testWidgets('la plage tient sur un téléphone étroit', (tester) async {
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Un débordement lèverait une exception de mise en page ici.
      await pumpGroup(
        tester,
        const StillWatchingSettings(fromMinute: 22 * 60, untilMinute: 6 * 60),
      );

      expect(find.text('Plage horaire'), findsOneWidget);
    });

    testWidgets('le nombre d’épisodes se choisit d’un appui', (tester) async {
      final changes = await pumpGroup(tester, const StillWatchingSettings());

      await tester.tap(find.widgetWithText(ChoiceChip, '5'));

      expect(changes.single.episodes, 5);
    });
  });
}
