import 'package:flutter/material.dart';
import '../widgets/global/sticky_glass_search.dart';

/// Tracks whether the video player route is on screen.
class SearchRouteObserver extends NavigatorObserver {
  static const playerRouteName = '/player';

  final ValueNotifier<bool> searchVisible = ValueNotifier(true);

  void _sync(Route<dynamic>? route) {
    searchVisible.value = route?.settings.name != playerRouteName;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sync(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sync(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sync(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _sync(newRoute);
  }
}

/// Inserts the sticky search into the navigator [Overlay] without wrapping the
/// navigator (avoids blank-screen rebuild loops in MaterialApp.builder).
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
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    widget.routeObserver.searchVisible.addListener(_syncOverlay);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOverlay());
  }

  @override
  void didUpdateWidget(covariant SearchOverlayScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routeObserver != widget.routeObserver) {
      oldWidget.routeObserver.searchVisible.removeListener(_syncOverlay);
      widget.routeObserver.searchVisible.addListener(_syncOverlay);
      _syncOverlay();
    }
  }

  @override
  void dispose() {
    widget.routeObserver.searchVisible.removeListener(_syncOverlay);
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _syncOverlay() {
    final overlay = widget.navigatorKey.currentState?.overlay;
    if (overlay == null || !mounted) return;

    if (!widget.routeObserver.searchVisible.value) {
      _entry?.remove();
      _entry = null;
      return;
    }

    final view = View.of(context);
    final isWide = view.physicalSize.width / view.devicePixelRatio >= 900;
    if (isWide) {
      _entry?.remove();
      _entry = null;
      return;
    }

    if (_entry == null) {
      _entry = OverlayEntry(
        builder: (context) {
          final top = MediaQuery.paddingOf(context).top + 10;
          return Positioned(
            top: top,
            right: 16,
            child: const StickyGlassSearch(),
          );
        },
      );
      overlay.insert(_entry!);
    } else if (_entry!.mounted) {
      _entry!.markNeedsBuild();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
