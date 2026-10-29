import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/models/my_request.dart';
import 'package:onyx/screens/requests/my_requests_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// « Mes demandes » montre ce que le compte a demandé et où ça en est, en
/// lots rendus par le serveur depuis MediaHub ou OnyxHub (ADR-0073, ADR-0087).

class _Api extends ApiClient {
  _Api(this.requests, {this.all = const [], this.access = RequestAccess.basic});
  final List<MyRequest> requests;
  final List<MyRequest> all;
  final RequestAccess access;
  final moderated = <(List<int>, RequestModeration, String?)>[];

  @override
  Future<List<MyRequest>> getMyRequests() async => requests;

  @override
  Future<List<MyRequest>> getAllRequests() async => all;

  @override
  Future<RequestAccess> getRequestAccess() async => access;

  @override
  Future<void> moderateRequests(List<int> requestIds, RequestModeration action,
      {String? reason}) async {
    moderated.add((requestIds, action, reason));
  }
}

const _moderator = RequestAccess(
  service: 'mediahub',
  linked: true,
  canRequest: true,
  canReadAll: true,
  canModerate: true,
  canDelete: false,
);

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
    expect(find.text('En cours'), findsOneWidget);
    expect(find.text('Saison 1'), findsOneWidget);
    expect(find.text('Disponible'), findsOneWidget);
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

  test('lit un lot de MediaHub : saisons, refus et raison d’attente', () {
    final request = MyRequest.fromJson({
      'requestIds': [41, 42],
      'tmdbId': 1399,
      'mediaType': 'tv',
      'title': 'Game of Thrones',
      'posterPath': null,
      'seasons': [1, 2],
      'status': 'partial',
      'seasonStatuses': [
        {'seasonNumber': 1, 'status': 'available'},
        {'seasonNumber': 2, 'status': 'declined'},
      ],
      'requestedAt': '2026-10-29T10:00:00.000Z',
      'updatedAt': '2026-10-29T11:30:00.000Z',
      'progress': null,
      'waiting': {
        'message': 'Pas encore sorti',
        'releaseDate': '2026-12-01T00:00:00Z',
      },
      'note': 'Doublon',
      'requester': 'lea',
    });
    expect(request.requestIds, [41, 42]);
    expect(request.seasonStatuses.last.status, MyRequestStatus.declined);
    expect(request.hasMixedSeasons, isTrue);
    expect(request.waitingMessage, 'Pas encore sorti');
    expect(request.releaseDate, DateTime.utc(2026, 12, 1));
    expect(request.note, 'Doublon');
    expect(request.requester, 'lea');
    // Une demande refusée se rouvre comme un titre qu'on peut redemander.
    expect(MyRequest.fromJson({'status': 'declined'}).toRequestItem().status,
        RequestMediaStatus.unknown);
  });

  testWidgets('une demande refusée dit pourquoi, une demande en attente aussi',
      (tester) async {
    const declined = MyRequest(
      tmdbId: 603,
      mediaType: RequestMediaType.movie,
      title: 'Matrix',
      posterPath: null,
      seasons: [],
      status: MyRequestStatus.declined,
      requestedAt: null,
      progress: null,
      note: 'Doublon',
    );
    const waiting = MyRequest(
      tmdbId: 604,
      mediaType: RequestMediaType.movie,
      title: 'Dune 3',
      posterPath: null,
      seasons: [],
      status: MyRequestStatus.approved,
      requestedAt: null,
      progress: null,
      waitingMessage: 'Pas encore sorti.',
    );
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: _Api([declined, waiting]),
      child: const MaterialApp(home: MyRequestsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Refusée : Doublon'), findsOneWidget);
    expect(find.text('Pas encore sorti.'), findsOneWidget);
    // Sans le droit de tout lire, pas de bascule vers les autres comptes.
    expect(find.text('Tous les comptes'), findsNothing);
  });

  testWidgets('une série aux saisons inégales montre chaque saison',
      (tester) async {
    const lot = MyRequest(
      tmdbId: 1399,
      mediaType: RequestMediaType.tv,
      title: 'Game of Thrones',
      posterPath: null,
      seasons: [1, 2],
      status: MyRequestStatus.partial,
      requestedAt: null,
      progress: null,
      seasonStatuses: [
        MyRequestSeason(number: 1, status: MyRequestStatus.available),
        MyRequestSeason(number: 2, status: MyRequestStatus.approved),
      ],
    );
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: _Api([lot]),
      child: const MaterialApp(home: MyRequestsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('S1 · Disponible'), findsOneWidget);
    expect(find.text('S2 · Approuvée'), findsOneWidget);
  });

  testWidgets('qui modère voit les demandes de tous et approuve un lot entier',
      (tester) async {
    const pending = MyRequest(
      requestIds: [41, 42],
      tmdbId: 1399,
      mediaType: RequestMediaType.tv,
      title: 'Game of Thrones',
      posterPath: null,
      seasons: [1, 2],
      status: MyRequestStatus.pending,
      requestedAt: null,
      progress: null,
      requester: 'hugo',
    );
    final api = _Api(const [], all: const [pending], access: _moderator);
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: api,
      child: const MaterialApp(home: MyRequestsScreen()),
    ));
    await tester.pumpAndSettle();
    // Ses propres demandes d'abord : la modération n'y apparaît pas.
    expect(find.text('Approuver'), findsNothing);

    await tester.tap(find.text('Tous les comptes'));
    await tester.pumpAndSettle();
    expect(find.text('Saisons 1, 2 · demandé par hugo'), findsOneWidget);

    await tester.tap(find.text('Approuver'));
    await tester.pumpAndSettle();
    expect(api.moderated.single.$1, [41, 42]);
    expect(api.moderated.single.$2, RequestModeration.approve);
    // Pas de suppression sans le droit delete de MediaHub.
    expect(find.text('Supprimer'), findsNothing);
  });

  testWidgets('refuser demande un motif, et l’envoie', (tester) async {
    const pending = MyRequest(
      requestIds: [40],
      tmdbId: 603,
      mediaType: RequestMediaType.movie,
      title: 'Matrix',
      posterPath: null,
      seasons: [],
      status: MyRequestStatus.pending,
      requestedAt: null,
      progress: null,
      requester: 'lea',
    );
    final api = _Api(const [], all: const [pending], access: _moderator);
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: api,
      child: const MaterialApp(home: MyRequestsScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tous les comptes'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Refuser'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Doublon');
    await tester.tap(find.widgetWithText(FilledButton, 'Refuser'));
    await tester.pumpAndSettle();
    expect(api.moderated.single.$2, RequestModeration.decline);
    expect(api.moderated.single.$3, 'Doublon');
  });
}
