import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/tv/tv_focus.dart';
import 'package:onyx/tv/tv_mode.dart';
import 'package:onyx/widgets/global/continue_watching_card.dart';
import 'package:provider/provider.dart';

/// Le menu d'une carte « Reprendre », tel qu'on l'ouvre à la télécommande en
/// gardant OK enfoncé : il doit rester ouvert et mener à la fiche du média.
void main() {
  final item = HomeMediaItem.fromJson({
    'id': 42,
    'type': 'movie',
    'title': 'Le film',
    'duration': 6000,
    'current_position_seconds': 600,
    'is_finished': false,
    'created_at': '2026-09-30T10:00:00Z',
  });

  testWidgets(
      "holding OK opens a menu that stays open and leads to the media's page",
      (tester) async {
    var plays = 0;
    var detailsOpened = 0;
    var watched = 0;

    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: ApiClient(),
        child: TvScope(
          isTv: true,
          child: MaterialApp(
            shortcuts: <ShortcutActivator, Intent>{
              ...WidgetsApp.defaultShortcuts,
              ...tvSelectShortcuts,
            },
            home: Scaffold(
              body: Center(
                child: ContinueWatchingCard(
                  item: item,
                  onTap: (_) => plays++,
                  onTitleTap: (_) => detailsOpened++,
                  onMarkAsWatched: (_) async => watched++,
                  onRemoveFromRow: (_) async {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Focus.of(tester.element(find.text('Le film'))).requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.text("Aller à l'affiche"), findsOneWidget,
        reason: 'the rest of the long press must not close the menu');
    expect(find.text('Marquer comme vu'), findsOneWidget);
    expect(find.text('Supprimer de Reprendre'), findsOneWidget);
    expect(watched, 0);
    expect(plays, 0);

    await tester.tap(find.text("Aller à l'affiche"));
    await tester.pumpAndSettle();

    expect(detailsOpened, 1);
    expect(plays, 0);
    expect(find.text("Aller à l'affiche"), findsNothing);
  });
}
