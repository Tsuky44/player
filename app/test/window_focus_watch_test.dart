import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/hooks/use_window_focus.dart';

ViewFocusEvent _event(ViewFocusState state) => ViewFocusEvent(
      viewId: 0,
      state: state,
      direction: ViewFocusDirection.undefined,
    );

void main() {
  test('la fenêtre est tenue pour active tant que le système ne dit rien', () {
    final watch = WindowFocusWatch(onRegained: () {});

    expect(watch.focused, isTrue);
  });

  test('une fenêtre qui perd le focus ne le réclame pas', () {
    var regained = 0;
    final watch = WindowFocusWatch(onRegained: () => regained++);

    watch.didChangeViewFocus(_event(ViewFocusState.unfocused));

    expect(watch.focused, isFalse);
    expect(regained, 0);
  });

  test('le retour du focus prévient une fois, pas à chaque annonce', () {
    var regained = 0;
    final watch = WindowFocusWatch(onRegained: () => regained++);

    watch.didChangeViewFocus(_event(ViewFocusState.unfocused));
    watch.didChangeViewFocus(_event(ViewFocusState.focused));
    watch.didChangeViewFocus(_event(ViewFocusState.focused));

    expect(watch.focused, isTrue);
    expect(regained, 1);
  });
}
