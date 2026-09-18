import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/widgets/global/media_card.dart';
import 'package:onyx/widgets/global/watch_badge.dart';
import 'package:provider/provider.dart';

/// La pastille de la bibliothèque : une coche verte pour ce qui est vu, un
/// décompte bleu pour une série entamée. Le verdict des séries vient du serveur
/// (`available/watched/started_episode_count`) et ne compte que les épisodes
/// réellement présents — « vu en entier » veut dire « tout ce que le serveur a ».
void main() {
  Media show({
    int? available,
    int? watched,
    int? started,
  }) {
    return Media.fromJson({
      'id': 7,
      'type': 'show',
      'title': 'Hebdo',
      'created_at': '2026-08-22T10:00:00Z',
      if (available != null) 'available_episode_count': available,
      if (watched != null) 'watched_episode_count': watched,
      if (started != null) 'started_episode_count': started,
    });
  }

  Media movie() => Media.fromJson({
        'id': 3,
        'type': 'movie',
        'title': 'Dune',
        'created_at': '2026-08-22T10:00:00Z',
      });

  Future<void> pumpCard(WidgetTester tester, Media media,
      {bool watched = false}) async {
    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: ApiClient(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 160,
                height: 280,
                child: MediaCard(
                  media: media,
                  watched: watched,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('état déduit du décompte', () {
    test('tous les épisodes disponibles vus ⇒ série vue', () {
      final m = show(available: 10, watched: 10);
      expect(m.isFullyWatched, isTrue);
      expect(m.isPartiallyWatched, isFalse);
    });

    test('une partie vue ⇒ série en cours, avec le reste à voir', () {
      final m = show(available: 10, watched: 4);
      expect(m.isFullyWatched, isFalse);
      expect(m.isPartiallyWatched, isTrue);
      expect(m.remainingEpisodeCount, 6);
    });

    test('un épisode seulement commencé suffit à marquer « en cours »', () {
      final m = show(available: 10, watched: 0, started: 1);
      expect(m.isPartiallyWatched, isTrue);
      expect(m.remainingEpisodeCount, 10);
    });

    test('série jamais ouverte ⇒ aucun état', () {
      final m = show(available: 10, watched: 0, started: 0);
      expect(m.isFullyWatched, isFalse);
      expect(m.isPartiallyWatched, isFalse);
    });

    test('série sans épisode indexé ne passe jamais pour vue', () {
      final m = show(available: 0, watched: 0);
      expect(m.isFullyWatched, isFalse);
    });

    test('payload sans décompte (ancien serveur) ⇒ aucun état', () {
      final m = show();
      expect(m.isFullyWatched, isFalse);
      expect(m.isPartiallyWatched, isFalse);
    });
  });

  testWidgets('série vue en entier : coche, pas de décompte', (tester) async {
    await pumpCard(tester, show(available: 10, watched: 10));

    expect(find.byType(WatchBadge), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.text('10'), findsNothing);
  });

  testWidgets('série en cours : le nombre d\'épisodes restants',
      (tester) async {
    await pumpCard(tester, show(available: 10, watched: 4));

    expect(find.text('6'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('série non commencée : aucune pastille', (tester) async {
    await pumpCard(tester, show(available: 10, watched: 0));

    expect(find.byType(WatchBadge), findsNothing);
  });

  testWidgets('film vu : coche ; film non vu : rien', (tester) async {
    await pumpCard(tester, movie(), watched: true);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await pumpCard(tester, movie());
    expect(find.byType(WatchBadge), findsNothing);
  });
}
