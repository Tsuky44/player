import 'dart:ui';

import 'package:flutter/material.dart';

const Color _kAccent = Color(0xFF007AFF);
const Color _kPanelBg = Color(0xFF1A1A1A);
const Color _kRowBg = Color(0xFF242424);
const Color _kRowSelectedBg = Color(0xFF2A3142);
const Color _kTabBg = Color(0xFF2A2A2A);

/// One tab entry in the player settings panel.
class PlayerSettingsTab {
  final IconData icon;
  final String label;

  const PlayerSettingsTab({required this.icon, required this.label});
}

/// Solid frosted shell for settings popups (no liquid glass — readable over video).
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
    return SizedBox(
      width: width,
      height: maxHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _kPanelBg.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 12, 0),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _kTabBg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.tune_rounded,
                          color: Colors.white70,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Paramètres',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'Manrope',
                                letterSpacing: -0.2,
                              ),
                            ),
                            Text(
                              'Audio, sous-titres et affichage',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                                fontFamily: 'Manrope',
                              ),
                            ),
                          ],
                        ),
                      ),
                      _CloseButton(onPressed: onClose),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: _SettingsTabStrip(
                    tabs: tabs,
                    selectedIndex: selectedTab,
                    onSelected: onTabSelected,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(child: child),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
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
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: _kTabBg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
        ),
      ),
    );
  }
}

class _SettingsTabStrip extends StatelessWidget {
  final List<PlayerSettingsTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _SettingsTabStrip({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _TabChip(
              tab: tabs[i],
              selected: i == selectedIndex,
              onTap: () => onSelected(i),
            ),
          ],
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final PlayerSettingsTab tab;
  final bool selected;
  final VoidCallback onTap;

  const _TabChip({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? _kAccent.withValues(alpha: 0.18) : _kTabBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? _kAccent.withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.06),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                tab.icon,
                size: 15,
                color: selected ? Colors.white : Colors.white60,
              ),
              const SizedBox(width: 6),
              Text(
                tab.label,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white60,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontFamily: 'Manrope',
                ),
              ),
            ],
          ),
        ),
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
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: selected ? _kRowSelectedBg : _kRowBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? _kAccent.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.05),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3,
                  height: 32,
                  margin: const EdgeInsets.only(top: 2, right: 10),
                  decoration: BoxDecoration(
                    color: selected ? _kAccent : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white70,
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                          fontFamily: 'Manrope',
                          height: 1.25,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 11,
                            fontFamily: 'Manrope',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (badge != null)
                  Container(
                    margin: const EdgeInsets.only(left: 8, top: 2),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Geist',
                      ),
                    ),
                  ),
                if (selected)
                  const Padding(
                    padding: EdgeInsets.only(left: 8, top: 4),
                    child: Icon(Icons.check_rounded, color: _kAccent, size: 18),
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
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: selected ? _kRowSelectedBg : _kRowBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? _kAccent.withValues(alpha: 0.45)
                    : Colors.white.withValues(alpha: 0.06),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: selected
                        ? _kAccent.withValues(alpha: 0.2)
                        : _kTabBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: selected ? Colors.white : Colors.white70,
                    size: 21,
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
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w600,
                          fontFamily: 'Manrope',
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                          fontFamily: 'Manrope',
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(Icons.check_circle_rounded,
                      color: _kAccent, size: 20),
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
