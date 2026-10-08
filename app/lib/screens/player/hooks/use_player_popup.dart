import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../tv/tv_focus.dart';
import '../../../tv/tv_mode.dart';

/// Le menu ouvert par-dessus le lecteur (réglages, sous-titres, séance), et
/// le chemin d'une télécommande pour y entrer et en sortir.
///
/// An [OverlayEntry] is not a route: nothing moves the focus into it, and
/// Back does not close it. On a television that leaves every menu the chrome
/// opens unreachable, and leaves Back meaning "quit the film" while a menu is
/// still on screen. So the content is wrapped in a focus scope the remote is
/// walked into, and the dismissal is registered where the player's own Back
/// handling can find it.
class PlayerPopupHost {
  PlayerPopupHost({required this.isActive, required this.onDismissed});

  /// Le lecteur est encore monté et ne se démonte pas.
  final bool Function() isActive;

  /// Un menu vient de se fermer, lecteur toujours là : le focus y revient.
  final VoidCallback onDismissed;

  /// Focus scope lent to whichever popup is open, so a remote can walk into a
  /// menu that is not a route and would otherwise never receive the focus.
  final FocusScopeNode _focusScope = FocusScopeNode(debugLabel: 'player-popup');

  /// The popup currently on the overlay, with the closure that dismisses it.
  /// Back goes through this before it reaches the player. One at a time: each
  /// of these covers the screen with its own dismiss barrier, so a second one
  /// stacked on it would be unreachable.
  ({OverlayEntry entry, VoidCallback dismiss})? _open;

  bool get isOpen => _open != null;

  /// Puts a popup on the overlay.
  ///
  /// [builder] receives the dismissal to wire into its barrier and its close
  /// button, in place of calling `entry.remove()` itself — going through it is
  /// what keeps the focus and the registration in step.
  void insert(
    BuildContext context,
    Widget Function(VoidCallback dismiss) builder,
  ) {
    // Never two at once; the one underneath could not be reached anyway.
    dismissTop();

    late final OverlayEntry entry;
    var dismissed = false;

    void dismiss() {
      if (dismissed) return;
      dismissed = true;
      if (identical(_open?.entry, entry)) _open = null;
      entry.remove();
      if (!isActive()) return;
      onDismissed();
    }

    entry = OverlayEntry(
      builder: (ctx) => FocusScope(
        node: _focusScope,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (kTvBackKeys.contains(event.logicalKey)) {
            dismiss();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: builder(dismiss),
      ),
    );

    _open = (entry: entry, dismiss: dismiss);
    Overlay.of(context).insert(entry);

    // Only a remote is walked in: on a desktop the pointer is already where
    // the user is looking, and stealing the focus would move it away.
    if (!TvMode.isTv) return;
    // After the frame — the scope has no children to offer until the entry
    // has been built at least once.
    //
    // The first focusable it finds is a floor, not a verdict: a menu knows
    // better than this method where its remote belongs — the track being
    // played, the row it was opened from — and says so from its own
    // post-frame callback, registered during the build this one waits for and
    // therefore running after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (dismissed || !isActive()) return;
      _focusScope.requestFocus();
      _focusScope.nextFocus();
    });
  }

  /// Closes the popup on screen, if there is one. Returns whether it did, so
  /// Back can stop there instead of also acting on the player.
  bool dismissTop() {
    final popup = _open;
    if (popup == null) return false;
    popup.dismiss();
    return true;
  }

  /// A menu belongs to the app's overlay, not to the player's route: left
  /// open, it would still be on screen after the player is gone.
  void dispose() {
    dismissTop();
    _focusScope.dispose();
  }
}
