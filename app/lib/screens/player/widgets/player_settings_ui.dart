import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// One tab entry in the player settings panel.
class PlayerSettingsTab {
  final IconData icon;
  final String label;

  const PlayerSettingsTab({required this.icon, required this.label});
}

BoxDecoration _panelDecoration({required BorderRadius radius}) {
  return BoxDecoration(
    color: AppColors.surface.withValues(alpha: 0.94),
    borderRadius: radius,
    border: Border.all(color: AppColors.glassBorder),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.55),
        blurRadius: 40,
        offset: const Offset(0, 18),
      ),
    ],
  );
}

/// Frosted shell for the subtitles-only popup.
class PlayerSubtitlesShell extends StatelessWidget {
  final VoidCallback onClose;
  final Widget child;
  final double width;
  final double maxHeight;

  const PlayerSubtitlesShell({
    super.key,
    required this.onClose,
    required this.child,
    required this.width,
    required this.maxHeight,
  });

  @override
  Widget build(BuildContext context) {
    return _PlayerPanelFrame(
      width: width,
      maxHeight: maxHeight,
      header: _PanelHeader(
        icon: Icons.subtitles_outlined,
        title: 'Sous-titres',
        subtitle: 'Choisir une piste',
        onClose: onClose,
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: child,
      ),
    );
  }
}

/// Frosted shell for settings popups (readable over video).
class PlayerSettingsShell extends StatelessWidget {
  final VoidCallback onClose;
  final List<PlayerSettingsTab> tabs;
  final int selectedTab;
  final ValueChanged<int> onTabSelected;
  final Widget child;
  final double width;
  final double maxHeight;

  const PlayerSettingsShell({
    super.key,
    required this.onClose,
    required this.tabs,
    required this.selectedTab,
    required this.onTabSelected,
    required this.child,
    required this.width,
    required this.maxHeight,
  });

  @override
  Widget build(BuildContext context) {
    return _PlayerPanelFrame(
      width: width,
      maxHeight: maxHeight,
      header: _PanelHeader(
        icon: Icons.tune_rounded,
        title: 'Paramètres',
        subtitle: 'Audio, sous-titres et affichage',
        onClose: onClose,
      ),
      belowHeader: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: _SettingsSegmentedTabs(
          tabs: tabs,
          selectedIndex: selectedTab,
          onSelected: onTabSelected,
        ),
      ),
      body: child,
    );
  }
}

class _PlayerPanelFrame extends StatelessWidget {
  final double width;
  final double maxHeight;
  final Widget header;
  final Widget? belowHeader;
  final Widget body;

  const _PlayerPanelFrame({
    required this.width,
    required this.maxHeight,
    required this.header,
    required this.body,
    this.belowHeader,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    // Height follows the content and only stops at maxHeight — a fixed height
    // left a two-track audio list floating in an empty half-screen panel.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
      child: SizedBox(
        width: width,
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: DecoratedBox(
              decoration: _panelDecoration(radius: radius),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Soft top highlight — glass edge, not decoration noise.
                  Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.0),
                          Colors.white.withValues(alpha: 0.16),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                  header,
                  if (belowHeader != null) belowHeader!,
                  Flexible(child: body),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  const _PanelHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Icon(icon, color: AppColors.textSecondary, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          _CloseButton(onPressed: onClose),
        ],
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _CloseButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: const Icon(
            Icons.close_rounded,
            color: AppColors.textSecondary,
            size: 18,
          ),
        ),
      ),
    );
  }
}

class _SettingsSegmentedTabs extends StatelessWidget {
  final List<PlayerSettingsTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _SettingsSegmentedTabs({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Horizontal scroll when many tabs (chapters).
          final useScroll = tabs.length > 4;
          final row = Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                useScroll
                    ? Padding(
                        padding: EdgeInsets.only(
                            right: i == tabs.length - 1 ? 0 : 4),
                        child: _SegmentTab(
                          tab: tabs[i],
                          selected: i == selectedIndex,
                          onTap: () => onSelected(i),
                          expanded: false,
                        ),
                      )
                    : Expanded(
                        child: _SegmentTab(
                          tab: tabs[i],
                          selected: i == selectedIndex,
                          onTap: () => onSelected(i),
                          expanded: true,
                        ),
                      ),
            ],
          );
          if (!useScroll) return row;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: row,
          );
        },
      ),
    );
  }
}

class _SegmentTab extends StatelessWidget {
  final PlayerSettingsTab tab;
  final bool selected;
  final VoidCallback onTap;
  final bool expanded;

  const _SegmentTab({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.symmetric(
        horizontal: expanded ? 6 : 12,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Icon(
            tab.icon,
            size: 14,
            color: selected ? AppColors.textPrimary : AppColors.textMuted,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              tab.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? AppColors.textPrimary : AppColors.textMuted,
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: -0.1,
              ),
            ),
          ),
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: content,
      ),
    );
  }
}

/// Selectable track row (audio / subtitles).
class PlayerSettingsTrackRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  const PlayerSettingsTrackRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.primary.withValues(alpha: 0.12)
                  : AppColors.surfaceElevated.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.45)
                    : AppColors.glassBorder,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                          height: 1.25,
                          letterSpacing: -0.1,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.glassBorder),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? AppColors.primary : Colors.transparent,
                    border: Border.all(
                      color: selected
                          ? AppColors.primary
                          : AppColors.textMuted.withValues(alpha: 0.55),
                      width: 1.5,
                    ),
                  ),
                  child: selected
                      ? const Icon(
                          Icons.check_rounded,
                          size: 13,
                          color: Colors.white,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Card-style option for display mode and quality.
class PlayerSettingsChoiceCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const PlayerSettingsChoiceCard({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.primary.withValues(alpha: 0.12)
                  : AppColors.surfaceElevated.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.45)
                    : AppColors.glassBorder,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.primary.withValues(alpha: 0.18)
                        : AppColors.background.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: Icon(
                    icon,
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Splits long track labels into a title + technical subtitle when possible.
(String title, String? subtitle) splitTrackLabel(String label) {
  final atIdx = label.indexOf('@');
  if (atIdx > 0 && atIdx < label.length - 2) {
    final title = label.substring(0, atIdx).trim();
    final rest = label.substring(atIdx).trim();
    if (title.isNotEmpty) return (title, rest);
  }
  if (label.length > 42) {
    final split = label.lastIndexOf(' ', 42);
    if (split > 12) {
      return (label.substring(0, split).trim(), label.substring(split).trim());
    }
  }
  return (label, null);
}
