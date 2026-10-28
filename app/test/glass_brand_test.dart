import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/widgets/global/glass_chrome.dart';
import 'package:onyx/widgets/global/onyx_mark.dart';
import 'package:onyx/widgets/global/onyx_wordmark.dart';

/// Le téléphone n'affiche que la lentille dans sa barre du haut, sur tous les
/// onglets. Le desktop garde le nom écrit.
void main() {
  Future<void> pumpBrand(WidgetTester tester, {required bool wordmark}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GlassBrand(showWordmark: wordmark)),
      ),
    );
  }

  testWidgets('sans nom, la marque se réduit à la lentille', (tester) async {
    await pumpBrand(tester, wordmark: false);
    expect(find.byType(OnyxMark), findsOneWidget);
    expect(find.byType(OnyxWordmark), findsNothing);
  });

  testWidgets('par défaut, le nom suit la lentille', (tester) async {
    await pumpBrand(tester, wordmark: true);
    expect(find.byType(OnyxMark), findsOneWidget);
    expect(find.byType(OnyxWordmark), findsOneWidget);
  });
}
