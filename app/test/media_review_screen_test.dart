import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/settings/media_review_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';

class ReviewApi extends ApiClient {
  @override
  Future<List<Media>> getMediaReviewQueue() async => [
        Media.fromJson({
          'id': 7,
          'type': 'movie',
          'title': 'fast and furious 7',
          'file_path': '/films/fast and furious 7.mkv',
          'created_at': '2026-09-08T12:00:00Z',
        }),
        Media.fromJson({
          'id': 8,
          'type': 'show',
          'title': 'Série sans affiche',
          'tmdb_id': 42,
          'overview': 'Synopsis présent',
          'release_date': '2021-01-01',
          'created_at': '2026-09-08T12:00:00Z',
        }),
      ];
}

void main() {
  testWidgets('shows persistent review reasons and manual actions',
      (tester) async {
    final api = ReviewApi();
    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: api,
        child: const MaterialApp(home: MediaReviewScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 fiches à vérifier'), findsOneWidget);
    expect(find.text('fast and furious 7'), findsOneWidget);
    expect(find.text('Non identifié'), findsOneWidget);
    expect(find.text('Affiche manquante'), findsNWidgets(2));
    expect(find.text('Choisir la fiche'), findsNWidgets(2));
  });
}
