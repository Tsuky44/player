part of 'onyx_settings_menu.dart';

// --- Rows ------------------------------------------------------------------

/// What makes a row reachable by a remote, and — the whole point — visible.
///
/// These rows used to be [InkWell]s. A remote could already walk them: the
/// arrows moved the focus exactly as they should. What it could not do is
/// *show* it. An ink highlight is painted by the enclosing [Material], which
/// here sits above the panel's own opaque background — so every ring, splash
/// and hover tint landed underneath it and never reached the screen. A menu
/// where nothing lights up is a menu a remote cannot be driven through, and it
/// reads from the sofa as an app that has stopped answering.
///
/// So the focus is drawn here instead, over the row: the accent ring
/// [TvFocusable] paints everywhere else in the app, plus a fill that carries
/// from three metres away. The pointer gets its own, quieter tint — it had
/// lost its hover state to the same burial.
class _OnyxMenuTile extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  /// Supplied for the one row the remote is sent to on arrival.
  final FocusNode? focusNode;

  const _OnyxMenuTile({
    required this.child,
    required this.onTap,
    this.focusNode,
  });

  @override
  State<_OnyxMenuTile> createState() => _OnyxMenuTileState();
}

class _OnyxMenuTileState extends State<_OnyxMenuTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: widget.focusNode,
      onSelect: widget.onTap,
      borderRadius: BorderRadius.circular(6),
      // Rows touch each other: growing one would climb over its neighbour.
      focusScale: 1.0,
      // A long list — twelve chapters — reads better with the outlined row
      // near the top than pinned to the middle.
      scrollAlignment: 0.3,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          // Read from the tree rather than kept in a flag of our own: the menu
          // hands one node from row to row as it changes section, so a row can
          // be built around a node that already holds the focus — and nothing
          // would ever announce a change that never happened.
          child: Builder(
            builder: (context) {
              final focused = Focus.of(context).hasFocus;
              return DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: focused
                      ? _focusFill
                      : _hovered
                          ? _hoverFill
                          : Colors.transparent,
                ),
                child: widget.child,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Reads from three metres away, on a surface that is already almost black.
final Color _focusFill = Colors.white.withValues(alpha: 0.14);

/// The pointer gets the quieter half of the same treatment.
final Color _hoverFill = Colors.white.withValues(alpha: 0.07);

/// Index row: what the setting is on, without opening it.
class _OnyxMenuRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  const _OnyxMenuRow({
    required this.label,
    required this.value,
    required this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return _OnyxMenuTile(
      onTap: onTap,
      focusNode: focusNode,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: OnyxChromeTheme.title,
                fontSize: AppType.body,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: OnyxChromeTheme.meta,
                  fontSize: AppType.subhead,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: OnyxChromeTheme.meta,
            ),
          ],
        ),
      ),
    );
  }
}

/// Choice row: a check occupies the left slot whether or not it is set, so the
/// labels stay on one vertical line.
class _OnyxMenuOption extends StatelessWidget {
  final String label;
  final String? subtitle;
  final String? value;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  const _OnyxMenuOption({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.value,
    this.badge,
    this.focusNode,
  });

  /// The entry node is placed by the list, which is the only thing that knows
  /// which option is the current one — the sections build their rows without
  /// looking at each other.
  _OnyxMenuOption withFocusNode(FocusNode? node) => _OnyxMenuOption(
        label: label,
        selected: selected,
        onTap: onTap,
        subtitle: subtitle,
        value: value,
        badge: badge,
        focusNode: node,
      );

  @override
  Widget build(BuildContext context) {
    return _OnyxMenuTile(
      onTap: onTap,
      focusNode: focusNode,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: selected
                  ? const Icon(Icons.check_rounded,
                      size: 17, color: OnyxChromeTheme.title)
                  : null,
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: OnyxChromeTheme.title,
                            fontSize: AppType.body,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        _OnyxMenuBadge(text: badge!),
                      ],
                    ],
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: OnyxChromeTheme.meta,
                          fontSize: AppType.footnote,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 8),
              Text(
                value!,
                style: const TextStyle(
                  color: OnyxChromeTheme.meta,
                  fontSize: AppType.footnote,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OnyxMenuBackHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _OnyxMenuBackHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return _OnyxMenuTile(
      onTap: onBack,
      child: Container(
        height: 44,
        padding: const EdgeInsets.only(left: 8, right: 16),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0x1AFFFFFF)),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.chevron_left_rounded,
                size: 22, color: OnyxChromeTheme.title),
            const SizedBox(width: 4),
            Text(
              title,
              style: const TextStyle(
                color: OnyxChromeTheme.title,
                fontSize: AppType.body,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnyxMenuBadge extends StatelessWidget {
  final String text;

  const _OnyxMenuBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        style: const TextStyle(color: OnyxChromeTheme.meta, fontSize: AppType.micro),
      ),
    );
  }
}

class _OnyxMenuEmpty extends StatelessWidget {
  const _OnyxMenuEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      child: Text(
        'Aucune piste disponible',
        style: TextStyle(color: OnyxChromeTheme.meta, fontSize: AppType.subhead),
      ),
    );
  }
}
