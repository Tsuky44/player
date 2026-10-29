import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/models/my_request.dart';
import 'package:onyx/screens/requests/my_requests_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// « Mes demandes » montre ce que le compte a demandé et où ça en est, au
/// format d'OnyxHub relayé tel quel par le serveur (ADR-0073).

class _Api extends ApiClient {
  _Api(this.requests);
  final List<MyRequest> requests;

  @override
  Future<List<MyRequest>> getMyRequests() async => requests;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('lit une demande au format d’OnyxHub', () {
    final request = MyRequest.fromJson({
      'tmdbId': 1399,
      'mediaType': 'tv',
      'title': 'Game of Thrones',
      'posterPath': '/got.jpg',
      'seasons': [1, 2],
      'status': 'processing',
      'requestedAt': '2026-10-20T10:00:00.000Z',
      'progress': 42.5,
    });
    expect(request.mediaType, RequestMediaType.tv);
    expect(request.seasons, [1, 2]);
    expect(request.status, MyRequestStatus.processing);
    expect(request.progress, 42.5);
    expect(request.posterUrl, 'https://image.tmdb.org/t/p/w185/got.jpg');
    // Toucher la demande ouvre sa fiche, rechargée depuis TMDB par son id.
    expect(request.toRequestItem().id, 1399);
    expect(request.toRequestItem().status, RequestMediaStatus.processing);
  });

  test(
      'un statut inconnu d’OnyxHub se lit « en attente », pas comme une erreur',
      () {
    expect(MyRequest.fromJson({'status': 'bientôt'}).status,
        MyRequestStatus.pending);
  });

  testWidgets(
      'chaque demande dit son statut, et sa progression pendant le téléchargement',
      (tester) async {
    const downloading = MyRequest(
      tmdbId: 603,
      mediaType: RequestMediaType.movie,
      title: 'Matrix',
      posterPath: null,
      seasons: [],
      status: MyRequestStatus.processing,
      requestedAt: null,
      progress: 40,
    );
    const done = MyRequest(
      tmdbId: 1399,
      mediaType: RequestMediaType.tv,
      title: 'Game of Thrones',
      posterPath: null,
      seasons: [1],
      status: MyRequestStatus.available,
      requestedAt: null,
      progress: null,
    );
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: _Api([downloading, done]),
      child: const MaterialApp(home: MyRequestsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Matrix'), findsOneWidget);
    // Libellés en capitales, comme les pastilles d'OnyxHub.
    expect(find.text('EN COURS'), findsOneWidget);
    expect(find.text('Saison 1'), findsOneWidget);
    expect(find.text('DISPONIBLE'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('sans demande, l’écran dit où elles apparaîtront',
      (tester) async {
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: _Api(const []),
      child: const MaterialApp(home: MyRequestsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Aucune demande'), findsOneWidget);
  });
}
