import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/offline_download.dart';
import 'package:onyx/screens/downloads/download_group_headers.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:provider/provider.dart';

/// Supprimer une saison ou une série d'un geste, depuis l'écran des
/// téléchargements : la question posée, et qui a droit au bouton.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  OfflineDownload entry(int id, {int season = 2}) => OfflineDownload(
        mediaId: id,
        type: MediaType.episode,
        title: 'Épisode $id',
        fileName: 'video.mkv',
        addedAt: DateTime(2026),
        showTitle: 'Ma série',
        showId: 7,
        seasonNumber: season,
        episodeNumber: id,
        bytesReceived: 1024 * 1024 * 512,
        bytesTotal: 1024 * 1024 * 512,
        status: DownloadStatus.completed,
      );

  Widget harness(Widget child) => ChangeNotifierProvider<DownloadManager>.value(
        value: DownloadManager.instance,
        child: MaterialApp(home: Scaffold(body: child)),
      );

  testWidgets('la saison se supprime après une question qui dit ce qui part',
      (tester) async {
    await tester.pumpWidget(harness(
      DownloadSeasonHeader(seasonNumber: 2, entries: [entry(1), entry(2)]),
    ));

    expect(find.text('Saison 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Supprimer la saison 2'));
    await tester.pumpAndSettle();

    expect(find.text('Supprimer la saison 2 ?'), findsOneWidget);
    expect(find.textContaining('2 éléments'), findsOneWidget);

    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('les épisodes spéciaux ne s’appellent pas « saison 0 »',
      (tester) async {
    await tester.pumpWidget(harness(
      DownloadSeasonHeader(seasonNumber: 0, entries: [entry(1, season: 0)]),
    ));

    expect(find.text('Épisodes spéciaux'), findsOneWidget);
    expect(find.byTooltip('Supprimer ces épisodes'), findsOneWidget);
  });

  testWidgets('une série a son bouton, le regroupement des films non',
      (tester) async {
    await tester.pumpWidget(harness(
      DownloadShowHeader(title: 'Ma série', infoId: null, entries: [entry(1)]),
    ));
    expect(find.byTooltip('Supprimer la série'), findsOneWidget);

    await tester.pumpWidget(harness(
      DownloadShowHeader(
        title: 'Films',
        infoId: null,
        entries: [entry(1)],
        deletable: false,
      ),
    ));
    expect(find.byTooltip('Supprimer la série'), findsNothing);
  });
}
