import 'package:flutter/widgets.dart';

/// The navigator inside `MainShell`, under the app's nav bar.
///
/// Detail pages open there so the nav bar stays on screen above them. A page
/// pushed from inside a tab reaches it on its own — it is the nearest
/// navigator. This key is for the pushes that start *outside* it, from the
/// nav bar itself (its search field).
///
/// The player does the opposite and goes to the root navigator: it is the one
/// page that has to cover everything.
final GlobalKey<NavigatorState> shellNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'shell');

/// The shell's navigator when there is one, the nearest navigator otherwise —
/// a television has no nested navigator, see `MainShell`.
NavigatorState shellNavigatorOf(BuildContext context) =>
    shellNavigatorKey.currentState ?? Navigator.of(context);
