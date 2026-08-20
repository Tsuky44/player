import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_focus.dart';
import 'package:onyx/tv/tv_mode.dart';

/// Mounts [child] the way the app does — inside a [TvScope] and with the
/// remote's `select` folded into the app-wide shortcuts.
Widget _app({required Widget child, bool isTv = true}) {
  return TvScope(
    isTv: isTv,
    child: MaterialApp(
      shortcuts: <ShortcutActivator, Intent>{
        ...WidgetsApp.defaultShortcuts,
        ...tvSelectShortcuts,
      },
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('select activates a focused card', (tester) async {
    var taps = 0;
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(_app(
      child: TvFocusable(
        focusNode: node,
        onSelect: () => taps++,
        child: const SizedBox(width: 100, height: 100),
      ),
    ));

    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(taps, 1, reason: 'the D-pad centre must activate the card');

    // The remote and the keyboard reach the same action.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump();
    expect(taps, 3);
  });

  testWidgets('holding select does not fire the action repeatedly',
      (tester) async {
    var taps = 0;
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(_app(
      child: TvFocusable(
        focusNode: node,
        onSelect: () => taps++,
        child: const SizedBox(width: 100, height: 100),
      ),
    ));

    node.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(taps, 1, reason: 'auto-repeat must not launch three episodes');
  });

  testWidgets('a disabled card is skipped by the remote', (tester) async {
    final before = FocusNode(debugLabel: 'before');
    final after = FocusNode(debugLabel: 'after');
    addTearDown(before.dispose);
    addTearDown(after.dispose);

    await tester.pumpWidget(_app(
      child: Column(
        children: [
          Focus(focusNode: before, child: const SizedBox(width: 10, height: 10)),
          TvFocusable(
            // An episode that has not aired yet: shown, not reachable.
            enabled: false,
            onSelect: () {},
            child: const SizedBox(width: 10, height: 10),
          ),
          Focus(focusNode: after, child: const SizedBox(width: 10, height: 10)),
        ],
      ),
    ));

    before.requestFocus();
    await tester.pump();

    before.nextFocus();
    await tester.pump();

    expect(after.hasFocus, isTrue,
        reason: 'the unreachable card must not be a dead stop for the D-pad');
  });

  testWidgets('the menu key opens the card context menu', (tester) async {
    var menus = 0;
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(_app(
      child: TvFocusable(
        focusNode: node,
        onSelect: () {},
        onContextMenu: () => menus++,
        child: const SizedBox(width: 100, height: 100),
      ),
    ));

    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump();

    expect(menus, 1);
  });

  testWidgets('a focused card is scrolled into view', (tester) async {
    final node = FocusNode();
    final controller = ScrollController();
    addTearDown(node.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(
      child: SizedBox(
        height: 200,
        child: SingleChildScrollView(
          controller: controller,
          child: Column(
            children: [
              const SizedBox(height: 1000),
              TvFocusable(
                focusNode: node,
                onSelect: () {},
                child: const SizedBox(height: 100, child: Text('cible')),
              ),
              const SizedBox(height: 1000),
            ],
          ),
        ),
      ),
    ));

    expect(controller.offset, 0);

    node.requestFocus();
    await tester.pumpAndSettle();

    // Focus that lands off-screen leaves the user with no cursor to follow, so
    // the viewport has to come to it.
    expect(controller.offset, greaterThan(0));
  });
}
