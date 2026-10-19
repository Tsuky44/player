import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../utils/responsive.dart';
import 'settings_page.dart';

/// Une page d'une catégorie : ce qu'une entrée de la navigation affichait
/// seule avant d'être regroupée avec ses voisines.
class SettingsSection {
  const SettingsSection({
    required this.id,
    required this.label,
    required this.builder,
  });

  /// Reste adressable : un lien vers « l'historique » ouvre l'onglet de la
  /// catégorie qui le porte.
  final String id;

  /// Le libellé de l'onglet. Une section empilée garde le titre de sa page.
  final String label;
  final WidgetBuilder builder;
}

/// Comment une catégorie montre plusieurs pages.
enum SettingsSectionsLayout {
  /// Sur un seul défilement : pour des pages courtes qu'on lit d'un trait.
  stacked,

  /// Derrière des onglets : pour des pages longues ou qui chargent beaucoup
  /// (listes, graphiques), qu'empiler rendrait interminables.
  tabbed,
}

/// Le contenu d'une catégorie, quelle que soit sa forme.
class SettingsCategoryBody extends StatelessWidget {
  const SettingsCategoryBody({
    super.key,
    required this.title,
    required this.sections,
    required this.layout,
    this.initialSection,
  });

  final String title;
  final List<SettingsSection> sections;
  final SettingsSectionsLayout layout;
  final String? initialSection;

  @override
  Widget build(BuildContext context) {
    if (sections.length > 1 && layout == SettingsSectionsLayout.tabbed) {
      return _TabbedSections(
        title: title,
        sections: sections,
        initialSection: initialSection,
      );
    }
    return SettingsPageFrame(
      title: title,
      appended: [
        for (final section in sections.skip(1))
          SettingsPageFrame.section(
            key: ValueKey(section.id),
            child: Builder(builder: section.builder),
          ),
      ],
      child: Builder(builder: sections.first.builder),
    );
  }
}

class _TabbedSections extends StatefulWidget {
  const _TabbedSections({
    required this.title,
    required this.sections,
    this.initialSection,
  });

  final String title;
  final List<SettingsSection> sections;
  final String? initialSection;

  @override
  State<_TabbedSections> createState() => _TabbedSectionsState();
}

class _TabbedSectionsState extends State<_TabbedSections> {
  late String _selected = _resolve(widget.initialSection);

  String _resolve(String? id) =>
      widget.sections.any((s) => s.id == id) ? id! : widget.sections.first.id;

  @override
  void didUpdateWidget(_TabbedSections oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSection != oldWidget.initialSection) {
      _selected = _resolve(widget.initialSection);
    } else if (!widget.sections.any((s) => s.id == _selected)) {
      _selected = widget.sections.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = SettingsLayout.maybeOf(context);
    final section = widget.sections.firstWhere((s) => s.id == _selected);

    // Un lien vers un onglet voisin (« Tout voir » du tableau de bord vers
    // l'historique) change d'onglet sur place ; vers ailleurs, il remonte à la
    // coquille.
    return SettingsLayout(
      isWide: parent?.isWide ?? false,
      openSection: (id) {
        if (widget.sections.any((s) => s.id == id)) {
          setState(() => _selected = id);
        } else {
          parent?.openSection(id);
        }
      },
      child: SettingsPageFrame(
        title: widget.title,
        tabs: _SectionTabBar(
          sections: widget.sections,
          selected: _selected,
          onSelect: (id) => setState(() => _selected = id),
        ),
        child: KeyedSubtree(
          key: ValueKey(section.id),
          child: Builder(builder: section.builder),
        ),
      ),
    );
  }
}

/// Les onglets d'une catégorie : une piste où l'onglet ouvert est éclairé.
/// Distincts des puces de filtre des pages, pour qu'on ne les confonde pas
/// avec un réglage.
class _SectionTabBar extends StatelessWidget {
  const _SectionTabBar({
    required this.sections,
    required this.selected,
    required this.onSelect,
  });

  final List<SettingsSection> sections;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final section in sections)
                _SectionTab(
                  label: section.label,
                  selected: section.id == selected,
                  onTap: () => onSelect(section.id),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTab extends StatefulWidget {
  const _SectionTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SectionTab> createState() => _SectionTabState();
}

class _SectionTabState extends State<_SectionTab> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: widget.onTap,
          onFocusChange: (value) => setState(() => _focused = value),
          child: AnimatedContainer(
            duration: AppMotion.fade(context, AppMotion.micro),
            curve: AppMotion.curve,
            constraints: BoxConstraints(
              minHeight: AppLayout.minTouchTarget(context) - 8,
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? AppColors.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: _focused
                    ? AppColors.primary.withValues(alpha: 0.8)
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: AppType.subhead,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
