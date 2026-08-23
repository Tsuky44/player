import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/widgets/global/continue_watching_card.dart';
import 'package:provider/provider.dart';

/// La pastille « Nouvel épisode » ne se décide pas dans l'app : le serveur
/// envoie `has_new_episode` sur les entrées de « À reprendre ». Ces tests
/// épinglent les deux bouts — la lecture du JSON et l'affichage.
void main() {
  HomeMediaItem episodeItem({required bool hasNewEpisode}) {
    return HomeMediaItem.fromJson({
      'id': 42,
      'type': 'episode',
      'title': 'Le retour',
      'duration': 2400,
      'current_position_seconds': 600,
      'is_finished': false,
      'show_id': 7,
      'show_title': 'Hebdo',
      'episode_title': 'Le retour',
      'season_number': 2,
      'episode_number': 5,
      'created_at': '2026-08-22T10:00:00Z',
      if (hasNewEpisode) 'has_new_episode': true,
    });
  }

  // L'affiche résout son URL via l'ApiClient : sans lui la carte ne se monte
  // pas, même quand aucune image n'est chargée.
  Future<void> pumpCard(WidgetTester tester, HomeMediaItem item) async {
    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: ApiClient(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ContinueWatchingCard(item: item, onTap: () {}),
            ),
          ),
        ),
      ),
    );
  }

  test('has_new_episode absent means no badge', () {
    expect(episodeItem(hasNewEpisode: false).hasNewEpisode, isFalse);
    expect(episodeItem(hasNewEpisode: true).hasNewEpisode, isTrue);
  });

  test('copyWith keeps the flag through a progress update', () {
    final updated = episodeItem(hasNewEpisode: true)
        .copyWith(currentPositionSeconds: 900);
    expect(updated.hasNewEpisode, isTrue);
    expect(updated.showId, 7);
  });

  testWidgets('badge shows only on a series with a new episode',
      (tester) async {
    await pumpCard(tester, episodeItem(hasNewEpisode: true));
    expect(find.text('Nouvel épisode'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpCard(tester, episodeItem(hasNewEpisode: false));
    expect(find.text('Nouvel épisode'), findsNothing);
  });
}
