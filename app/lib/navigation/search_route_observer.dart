import 'package:flutter/material.dart';

/// Tracks navigator stack / player route for search chrome visibility.
class SearchRouteObserver extends NavigatorObserver {
  static const playerRouteName = '/player';

  /// True only on the root shell (not player, not pushed detail screens).
  final ValueNotifier<bool> searchVisible = ValueNotifier(true);

  int _stackDepth = 0;
  String? _topRouteName;

  void _updateVisibility() {
    final onPlayer = _topRouteName == playerRouteName;
    searchVisible.value = _stackDepth <= 1 && !onPlayer;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stackDepth++;
    _topRouteName = route.settings.name;
    _updateVisibility();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stackDepth = (_stackDepth - 1).clamp(0, 1000);
    _topRouteName = previousRoute?.settings.name;
    _updateVisibility();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stackDepth = (_stackDepth - 1).clamp(0, 1000);
    _topRouteName = previousRoute?.settings.name;
    _updateVisibility();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _topRouteName = newRoute?.settings.name;
    _updateVisibility();
  }
}

/// Keeps [SearchRouteObserver] wiring without a floating overlay.
///
/// Mobile search lives in the home / shell chrome so it cannot cover the
/// account avatar. This scope remains for API compatibility with [MaterialApp].
class SearchOverlayScope extends StatefulWidget {
  final SearchRouteObserver routeObserver;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const SearchOverlayScope({
    super.key,
    required this.routeObserver,
    required this.navigatorKey,
    required this.child,
  });

  @override
  State<SearchOverlayScope> createState() => _SearchOverlayScopeState();
}

class _SearchOverlayScopeState extends State<SearchOverlayScope> {
  @override
  Widget build(BuildContext context) => widget.child;
}
