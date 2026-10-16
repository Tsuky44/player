import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_share.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/settings/pages/shares_page.dart';
import 'package:onyx/screens/settings/widgets/share_viewers.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';

/// Une doublure qui rend les liens tels que GET /api/shares les décrit.
class _Api extends ApiClient {
  _Api(this.json);
  final List<Map<String, dynamic>> json;

  @override
  Future<List<MediaShare>> listMediaShares() async =>
      json.map(MediaShare.fromJson).toList();
}

class _Auth extends AuthProvider {
  _Auth(super.api);
  @override
  Permissions get permissions => const Permissions(shareMedia: true);
}

void main() {
  final now = DateTime(2026, 10, 16, 22);

  group('shareViewerProgress', () {
    MediaShareViewer viewer(Map<String, dynamic> json) =>
        MediaShareViewer.fromJson({'name': 'Marie', 'media_id': 7, ...json});

    test('un épisode en cours dit lequel et où', () {
      expect(
        shareViewerProgress(
            viewer({
              'season_number': 1,
              'episode_number': 3,
              'position_seconds': 1450,
              'duration': 3000,
              'watched_at': DateTime(2026, 10, 16, 21, 4).toUtc().toIso8601String(),
            }),
            now: now),
        'S1 E3 · à 24:10 · il y a 56 min',
      );
    });

    test('un épisode vu ne donne plus de position', () {
      expect(
        shareViewerProgress(
            viewer({'season_number': 2, 'episode_number': 1, 'finished': true})),
        'S2 E1 · vu',
      );
    });

    test('un film dit sa position, ou « Vu »', () {
      expect(shareViewerProgress(viewer({'position_seconds': 3730})),
          'à 01:02:10');
      expect(shareViewerProgress(viewer({'finished': true})), 'Vu');
    });
  });

  testWidgets(
      'le créateur voit sous chaque lien qui le regarde et où chacun en est',
      (tester) async {
    final api = _Api([
      {
        'id': 1,
        'media_id': 2,
        'media_type': 'season',
        'title': 'Lioness',
        'subtitle': 'Saison 1',
        'status': 'active',
        'viewers': [
          {
            'name': 'Paul',
            'media_id': 11,
            'season_number': 1,
            'episode_number': 1,
            'position_seconds': 0,
            'finished': true,
            'watched_at': '2026-10-15T19:00:00Z',
          },
          {
            'name': 'Marie',
            'media_id': 15,
            'season_number': 1,
            'episode_number': 3,
            'position_seconds': 600,
            'duration': 3000,
            'finished': false,
            'watched_at': '2026-10-14T19:00:00Z',
          },
        ],
      },
      {
        'id': 2,
        'media_id': 9,
        'media_type': 'movie',
        'title': 'Dune',
        'status': 'active',
      },
    ]);
    final auth = _Auth(api);
    addTearDown(auth.dispose);

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ],
      child: const MaterialApp(home: Scaffold(body: SharesPage())),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Lioness · Saison 1'), findsOneWidget);
    expect(find.byType(ShareViewersList), findsOneWidget,
        reason: 'un lien que personne n’a ouvert sous un prénom n’a pas de liste');
    expect(find.textContaining('Paul  S1 E1 · vu', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('Marie  S1 E3 · à 10:00', findRichText: true),
        findsOneWidget);

    final paul = tester.getTopLeft(find.textContaining('Paul', findRichText: true));
    final marie =
        tester.getTopLeft(find.textContaining('Marie', findRichText: true));
    expect(paul.dy, lessThan(marie.dy),
        reason: 'l’ordre du serveur, le plus récent d’abord, est gardé');
  });
}
