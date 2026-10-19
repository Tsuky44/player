import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/announcement.dart';
import 'package:onyx/widgets/global/announcement_dialog.dart';

Future<void> _open(WidgetTester tester, ServerAnnouncement announcement,
    {Size size = const Size(375, 812)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => showAnnouncementDialog(context, announcement),
          child: const Text('ouvrir'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('un long message tient sur un téléphone et défile', (tester) async {
    await _open(
      tester,
      ServerAnnouncement(
        id: 1,
        title: 'Maintenance du serveur',
        message: List.filled(200, 'Le serveur redémarre ce soir.').join(' '),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Maintenance du serveur'), findsOneWidget);
  });

  testWidgets('sans titre, la fenêtre dit d’où vient le message', (tester) async {
    await _open(tester,
        const ServerAnnouncement(id: 1, title: '', message: 'Bonjour'));
    expect(find.text('Un message de votre serveur'), findsOneWidget);
  });

  testWidgets('le bouton a le focus et seul lui ferme la fenêtre',
      (tester) async {
    await _open(tester,
        const ServerAnnouncement(id: 1, title: 'Titre', message: 'Bonjour'));

    // Un tap à côté ne la ferme pas : le message passerait pour lu.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AnnouncementDialog), findsOneWidget);

    final button = find.byType(FilledButton);
    expect(Focus.of(tester.element(find.text('J’ai compris'))).hasFocus, isTrue);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(AnnouncementDialog), findsNothing);
  });
}
