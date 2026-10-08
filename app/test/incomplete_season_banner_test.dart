import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/library/widgets/missing_season_banner.dart';

/// Une saison présente mais incomplète (série en cours de diffusion) dit si la
/// suite est demandée, et se laisse demander quand le serveur l'autorise.
void main() {
  Media heldSeason({required String status, required bool canRequest}) =>
      Media.fromJson({
        'id': 12,
        'type': 'season',
        'title': 'Saison 2',
        'season_number': 2,
        'duration': 0,
        'is_available': true,
        'request_status': status,
        'can_request': canRequest,
        'episode_count': 10,
      });

  Future<void> pump(WidgetTester tester, Media season) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MissingSeasonBanner(
              season: season,
              requestableCount: 1,
              submitting: false,
              onRequest: () {},
              onRequestMore: () {},
            ),
          ),
        ),
      );

  testWidgets('une saison incomplète jamais demandée propose la demande',
      (tester) async {
    await pump(tester, heldSeason(status: 'unknown', canRequest: true));

    expect(find.text('Saison incomplète sur le serveur'), findsOneWidget);
    expect(find.text('Demander la saison 2'), findsOneWidget);
    expect(find.text('Saison manquante sur le serveur'), findsNothing);
  });

  testWidgets('une saison incomplète déjà demandée le dit, sans bouton',
      (tester) async {
    await pump(tester, heldSeason(status: 'pending', canRequest: false));

    expect(
      find.text('Saison demandée, les épisodes manquants arriveront'),
      findsOneWidget,
    );
    expect(find.text('Demander la saison 2'), findsNothing);
  });
}
