import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/theme/app_icons.dart';
import 'package:onyx/widgets/global/episode_tile.dart';
import 'package:provider/provider.dart';

/// Le numéro d'un épisode vu reste lisible dans la liste de la série : le
/// remplacer par une coche obligeait à compter les lignes pour se repérer.
void main() {
  HomeMediaItem episode({required bool finished}) => HomeMediaItem(
        media: Media(
          id: 42,
          type: MediaType.episode,
          title: 'Le retour',
          duration: 2400,
          createdAt: DateTime(2026),
        ),
        currentPositionSeconds: finished ? 2400 : 0,
        duration: 2400,
        isFinished: finished,
      );

  Future<void> pumpTile(WidgetTester tester, HomeMediaItem item) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient();
    final auth = AuthProvider(api);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EpisodeTile(
              episode: item,
              episodeNumber: 7,
              allowDownload: false,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('un épisode vu garde son numéro, avec une coche discrète',
      (tester) async {
    await pumpTile(tester, episode(finished: true));

    expect(find.text('7'), findsOneWidget);
    expect(find.byIcon(AppIcons.check), findsOneWidget);
  });

  testWidgets('un épisode non vu montre son numéro sans coche',
      (tester) async {
    await pumpTile(tester, episode(finished: false));

    expect(find.text('7'), findsOneWidget);
    expect(find.byIcon(AppIcons.check), findsNothing);
  });
}
