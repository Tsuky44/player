import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/library/widgets/catalog_header.dart';

void main() {
  testWidgets('le tri reste collé au bord droit, quel que soit le titre',
      (tester) async {
    for (final title in ['Films', 'Une bibliothèque au nom bien plus long']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              child: CatalogHeader<int>(
                title: title,
                countLabel: '28 titres',
                sortOptions: const {0: 'Récents', 1: 'A → Z'},
                sort: 0,
                onSortChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      final sortRight = tester.getTopRight(find.byType(PopupMenuButton<int>));
      final headerRight = tester.getTopRight(find.byType(CatalogHeader<int>));
      expect(sortRight.dx, headerRight.dx, reason: title);
    }
  });
}
