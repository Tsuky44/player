import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../utils/app_platform.dart';
import 'tv_focus_memory.dart';
import 'tv_key_repeat.dart';
import 'tv_mode.dart';

/// Keys that mean "activate the thing under the cursor".
///
/// A television remote sends `select` (KEYCODE_DPAD_CENTER); a game controller
/// paired to the same box sends `gameButtonA`; a USB keyboard someone plugged
/// into the TV sends `enter` or `space`. All four are the same gesture, so all
/// four are listed here rather than special-cased per widget.
// Not `const`: LogicalKeyboardKey defines its own ==, which Dart refuses in a
// constant set.
final Set<LogicalKeyboardKey> kTvSelectKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.gameButtonA,
};

/// Keys that mean "go back one step".
///
/// Android TV's remote sends `goBack`; the Siri Remote's Menu button and a
/// keyboard send `escape`; a game controller sends `gameButtonB`. The player
/// and its menus unwind one layer per press on any of them.
final Set<LogicalKeyboardKey> kTvBackKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.goBack,
  LogicalKeyboardKey.browserBack,
  LogicalKeyboardKey.gameButtonB,
};

/// Shortcuts merged into the app's defaults so `select` and the controller's A
/// button activate anything Flutter already activates with Enter — every
/// Material button, tile and menu item, without touching a single one of them.
///
/// The back keys first try [DismissIntent], like Escape always has: whatever
/// can close itself (a dialog, a menu) does. Anything left over becomes a
/// [TvBackIntent].
Map<ShortcutActivator, Intent> get tvSelectShortcuts =>
    const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.escape): _dismissThenBack,
      SingleActivator(LogicalKeyboardKey.goBack): _dismissThenBack,
      SingleActivator(LogicalKeyboardKey.gameButtonB): _dismissThenBack,
    };

const Intent _dismissThenBack = PrioritizedIntents(
  orderedIntents: <Intent>[DismissIntent(), TvBackIntent()],
);

/// "Go back one step", once nothing closer to the focus wanted the key.
class TvBackIntent extends Intent {
  const TvBackIntent();
}

/// Back, on a television that is not Android.
///
/// Android TV's Back key goes through the system, which sends Flutter a
/// `popRoute` — the same path as the phone's back gesture, so every
/// [PopScope] in the app already knows what to do with it. iOS has no system
/// back: an Apple remote or a controller only produces a key event, which by
/// default nothing turns into navigation. This does what Flutter does with
/// that `popRoute` — `maybePop` on the root navigator, which runs the same
/// [PopScope]s — so one press of Back does the same thing on both.
///
/// Disabled off a television (Escape keeps its desktop meaning) and on Android
/// (the system already does it; doing it here too would pop twice).
class TvBackAction extends Action<TvBackIntent> {
  @override
  bool isEnabled(TvBackIntent intent) => TvMode.isTv && !AppPlatform.isAndroid;

  @override
  Object? invoke(TvBackIntent intent) {
    final context = primaryFocus?.context;
    if (context == null) return null;
    return Navigator.maybeOf(context, rootNavigator: true)?.maybePop();
  }
}

/// Makes an arbitrary widget reachable and activatable with a D-pad.
///
/// The app's cards are `InkWell`s inside custom layouts: they take taps and
/// they take hovers, but a remote cannot reach them because nothing in that
/// stack requests focus. This wraps them so it can — and paints the focus, in a
/// way a person reads from three metres away.
///
/// Off a television this is deliberately close to inert: the child is still
/// wrapped in a [Focus] so a keyboard user on desktop can tab through, but the
/// zoom is dropped and the ring only appears when Flutter itself says the
/// highlight is warranted. Nothing about the touch path changes — the child
/// keeps its own gesture handling, and [onSelect] is the remote's way in, not a
/// replacement for it.
class TvFocusable extends StatefulWidget {
  final Widget child;

  /// Invoked on `select` / Enter / A. Usually the same callback the child's
  /// `onTap` already has.
  final VoidCallback? onSelect;

  /// Invoked on the remote's menu / long-press equivalent, where the widget has
  /// a context menu worth reaching.
  final VoidCallback? onContextMenu;

  final FocusNode? focusNode;
  final bool autofocus;

  /// False for a card that is present but not actionable (an unavailable
  /// episode, a disabled button): it stays visible and stays unreachable.
  final bool enabled;

  /// Matches the child's own clipping so the ring hugs the artwork instead of
  /// boxing it.
  final BorderRadius borderRadius;

  /// How much the child grows when focused. 1.0 disables the zoom for widgets
  /// that live in a tight grid where growing would overlap a neighbour.
  final double focusScale;

  /// Where the focused child should sit once scrolled into view. 0.5 centres
  /// it, which is what a horizontal poster row wants; a tall list reads better
  /// nearer the top.
  final double scrollAlignment;

  /// False where the child already draws its own focus treatment — a poster
  /// card lights up its artwork, and a second rectangle around the title text
  /// underneath it would only be noise.
  final bool showRing;

  final ValueChanged<bool>? onFocusChange;

  const TvFocusable({
    super.key,
    required this.child,
    this.onSelect,
    this.onContextMenu,
    this.focusNode,
    this.autofocus = false,
    this.enabled = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.focusScale = 1.05,
    this.scrollAlignment = 0.5,
    this.showRing = true,
    this.onFocusChange,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  /// Créé quand l'appelant n'en fournit pas : la mémoire de la rangée a besoin
  /// d'un nœud à qui rendre le focus.
  FocusNode? _ownedNode;

  /// La mémoire la plus proche, gardée ici parce qu'on doit pouvoir la prévenir
  /// depuis [dispose], où l'arbre ne se consulte plus.
  TvFocusMemoryState? _memory;

  /// OK est enfoncé sur une carte qui a un menu : l'action part au relâchement,
  /// sauf si l'appui a duré assez longtemps pour devenir un appui long.
  bool _selectPending = false;
  bool _longPressFired = false;

  FocusNode get _node =>
      widget.focusNode ?? (_ownedNode ??= FocusNode(debugLabel: 'tv-focusable'));

  /// A node can arrive already holding the focus.
  ///
  /// `onFocusChange` reports a *change*, and there is none: the player's
  /// settings menu moves one node from row to row as it changes section, so
  /// the row that inherits it was built around a node that never lost the
  /// focus. Reading the node instead of waiting to be told is what keeps the
  /// ring from being missing on the one row that has it.
  @override
  void initState() {
    super.initState();
    _focused = widget.focusNode?.hasFocus ?? false;
    if (_focused) _scrollIntoView();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _memory = TvFocusMemory.maybeOf(context);
  }

  /// Same case, one step later: the node was handed to a row that already
  /// exists. No rebuild is needed — [didUpdateWidget] is followed by [build].
  @override
  void didUpdateWidget(TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode == oldWidget.focusNode) return;
    if (oldWidget.focusNode != null) _memory?.forget(oldWidget.focusNode!);
    final focused = _node.hasFocus;
    if (focused == _focused) return;
    _focused = focused;
    if (_focused) _scrollIntoView();
  }

  @override
  void dispose() {
    _memory?.forget(_node);
    _ownedNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange(bool focused) {
    if (_focused != focused) {
      setState(() => _focused = focused);
    }
    widget.onFocusChange?.call(focused);

    if (!focused) {
      _selectPending = false;
      return;
    }
    _memory?.remember(_node);
    _scrollIntoView();
  }

  void _scrollIntoView() {
    // Scrolling has to wait for the frame that granted the focus: the row may
    // still be laying out (a grid that just built the cell, a page that just
    // pushed), and ensureVisible on a stale geometry scrolls to the wrong spot.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Plus le focus : une rangée qui se souvient l'a déjà rendu à une autre
      // carte, et défiler jusqu'à celle-ci ferait un aller-retour visible.
      if (!mounted || !_node.hasFocus) return;
      Scrollable.ensureVisible(
        context,
        alignment: widget.scrollAlignment,
        // Every scrollable between here and the root, so a poster in a
        // horizontal row inside a vertical page centres on both axes.
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        // Plus court quand la flèche est maintenue : l'animation doit finir
        // avant le déplacement suivant, sinon le focus court devant la rangée.
        duration: TvKeyRepeat.isRepeating
            ? const Duration(milliseconds: 90)
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;

    if (kTvSelectKeys.contains(event.logicalKey)) {
      final onSelect = widget.onSelect;
      final onContextMenu = widget.onContextMenu;

      // Une carte qui a un menu distingue l'appui court de l'appui long, comme
      // Android TV : l'action part au relâchement, le menu quand la touche est
      // restée enfoncée assez longtemps pour se répéter.
      if (onContextMenu != null &&
          (context.getInheritedWidgetOfExactType<TvScope>()?.isTv ?? false)) {
        if (event is KeyDownEvent) {
          _selectPending = true;
          _longPressFired = false;
          return KeyEventResult.handled;
        }
        if (event is KeyRepeatEvent) {
          if (_selectPending && !_longPressFired) {
            _longPressFired = true;
            onContextMenu();
          }
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) {
          final fire = _selectPending && !_longPressFired;
          _selectPending = false;
          _longPressFired = false;
          if (!fire || onSelect == null) return KeyEventResult.ignored;
          onSelect();
          return KeyEventResult.handled;
        }
      }

      // Holding select must not fire the action forty times.
      if (event is! KeyDownEvent) {
        return onSelect == null
            ? KeyEventResult.ignored
            : KeyEventResult.handled;
      }
      if (onSelect == null) return KeyEventResult.ignored;
      onSelect();
      return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.contextMenu ||
        event.logicalKey == LogicalKeyboardKey.gameButtonY) {
      final onContextMenu = widget.onContextMenu;
      if (onContextMenu == null) return KeyEventResult.ignored;
      onContextMenu();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isTv = TvScope.of(context);

    // The stack is unconditional even though the ring is not: swapping the
    // child between "wrapped" and "bare" rebuilds its whole subtree, which
    // restarts every poster's fade-in the instant focus moves.
    Widget content = Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        // The ring sits over the child rather than around it: adding a border
        // to the layout would shift every sibling by two pixels the moment
        // focus lands, and a grid that twitches as you scan it is worse than
        // no ring at all.
        if (_focused && widget.showRing)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: widget.borderRadius,
                  border: Border.all(color: AppColors.accent, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.35),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );

    // The zoom is a television affordance. On a phone or a desktop it would
    // fight the hover states the cards already have.
    if (isTv && widget.focusScale != 1.0) {
      content = AnimatedScale(
        scale: _focused ? widget.focusScale : 1.0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: content,
      );
    }

    return Focus(
      focusNode: _node,
      // Only on a television. Grabbing the focus on a phone pops the
      // keyboard and paints a ring nobody asked for.
      autofocus: widget.autofocus && widget.enabled && TvMode.isTv,
      canRequestFocus: widget.enabled,
      // A wrapper that cannot itself be focused must not swallow its subtree
      // either, or a disabled card would block the row behind it.
      descendantsAreFocusable: widget.enabled,
      onFocusChange: _handleFocusChange,
      onKeyEvent: _handleKey,
      child: Semantics(
        button: widget.onSelect != null,
        child: content,
      ),
    );
  }
}

/// Paints the television focus ring on a widget whose focus is held just above
/// it — the face of a [PopupMenuButton], whose own ink well owns the node.
///
/// Material's focus treatment for those is a faint wash of colour, which reads
/// on a monitor at arm's length and not from a sofa. Off a television this
/// draws nothing.
class TvFocusHalo extends StatelessWidget {
  const TvFocusHalo({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final focused = TvScope.of(context) &&
        (Focus.maybeOf(context)?.hasPrimaryFocus ?? false);
    return AnimatedScale(
      scale: focused ? 1.05 : 1.0,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: focused ? AppColors.accent : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: child,
      ),
    );
  }
}
