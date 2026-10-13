import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/home_provider.dart';
import 'package:onyx/screens/home/home_empty_view.dart';
import 'package:onyx/services/api_client.dart';

/// Un serveur neuf n'a aucune bibliothèque : il n'en impose pas (ADR-0058).
/// L'accueil dit alors quoi faire à qui peut le faire.

const _films = MediaLibrary(id: 1, name: 'Films', kind: LibraryKind.movies);

Future<void> _pump(
  WidgetTester tester, {
  required List<MediaLibrary>? libraries,
  required Permissions permissions,
}) async {
  final home = HomeProvider(ApiClient());
  addTearDown(home.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: HomeEmptyView(
        libraries: libraries,
        permissions: permissions,
        homeProvider: home,
      ),
    ),
  ));
}

void main() {
  testWidgets('sans bibliothèque, l’administrateur est mené à en ajouter une',
      (tester) async {
    await _pump(tester, libraries: const [], permissions: Permissions.all);

    expect(find.text('Aucune bibliothèque'), findsOneWidget);
    expect(find.text('Ajouter une bibliothèque'), findsOneWidget);
    // Rien à analyser tant qu'aucun dossier n'est déclaré.
    expect(find.text('Synchroniser'), findsNothing);
  });

  testWidgets('sans bibliothèque, un compte simple n’a aucun bouton',
      (tester) async {
    await _pump(tester,
        libraries: const [], permissions: const Permissions(requestMedia: true));

    expect(find.text('Aucune bibliothèque'), findsOneWidget);
    expect(find.text('Ajouter une bibliothèque'), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('des bibliothèques encore vides : il reste à synchroniser',
      (tester) async {
    await _pump(tester, libraries: const [_films], permissions: Permissions.all);

    expect(find.text('Bibliothèque vide'), findsOneWidget);
    expect(find.text('Synchroniser'), findsOneWidget);
    expect(find.text('Ajouter une bibliothèque'), findsNothing);
  });

  testWidgets('tant que la liste n’est pas arrivée, on ne conclut pas qu’elle '
      'est vide', (tester) async {
    await _pump(tester, libraries: null, permissions: Permissions.all);

    expect(find.text('Aucune bibliothèque'), findsNothing);
    expect(find.text('Bibliothèque vide'), findsOneWidget);
  });
}
