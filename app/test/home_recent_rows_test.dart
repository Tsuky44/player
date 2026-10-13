import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/home/home_recent_rows.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Les rangées de l'accueil portent le nom des bibliothèques du serveur
/// (ADR-0058) : l'app n'en écrit plus le titre.

Map<String, dynamic> _media(int id, String type, String title) => {
      'id': id,
      'type': type,
      'title': title,
      'created_at': '2026-09-01T10:00:00Z',
    };

Future<List<int>> _pump(WidgetTester tester, HomeResponse data) async {
  tester.view.physicalSize = const Size(1300, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final opened = <int>[];
  await tester.pumpWidget(Provider<ApiClient>.value(
    value: ApiClient(),
    child: MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: homeRecentSlivers(
            data: data,
            isTv: false,
            onOpenLibrary: opened.add,
            onSeeAllMovies: () => opened.add(-1),
            onSeeAllShows: () => opened.add(-2),
            onOpenMedia: (_) {},
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return opened;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('une rangée par bibliothèque, sous son nom', (tester) async {
    final data = HomeResponse.fromJson({
      'recent_movies': [_media(1, 'movie', 'Noël 2019')],
      'recent_shows': [_media(2, 'show', 'Naruto')],
      'libraries': [
        {
          'id': 4,
          'name': 'Vidéos de famille',
          'kind': 'other',
          'items': [_media(1, 'movie', 'Noël 2019')],
        },
        {
          'id': 7,
          'name': 'Animés',
          'kind': 'shows',
          'items': [_media(2, 'show', 'Naruto')],
        },
      ],
    });
    expect(data.libraries.first.kind, LibraryKind.other);

    await _pump(tester, data);

    expect(find.text('Derniers ajouts · Vidéos de famille'), findsOneWidget);
    expect(find.text('Derniers ajouts · Animés'), findsOneWidget);
    expect(find.text('Films récents'), findsNothing);
    expect(find.text('Séries récentes'), findsNothing);
    expect(find.text('Noël 2019'), findsOneWidget);
    expect(find.text('Naruto'), findsOneWidget);
  });

  // Un serveur d'avant les bibliothèques (ADR-0013) n'envoie pas ces rangées.
  testWidgets('un serveur plus ancien garde ses deux rangées', (tester) async {
    final data = HomeResponse.fromJson({
      'recent_movies': [_media(1, 'movie', 'Dune')],
      'recent_shows': <Object>[],
    });

    await _pump(tester, data);

    expect(find.text('Films récents'), findsOneWidget);
    // Une rangée vide ne s'affiche pas.
    expect(find.text('Séries récentes'), findsNothing);
    expect(find.textContaining('Derniers ajouts'), findsNothing);
  });
}
