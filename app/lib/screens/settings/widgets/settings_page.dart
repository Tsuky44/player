import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_type.dart';

/// Ce que la coquille dit aux pages : sont-elles affichées à côté de la
/// navigation (titre dans la page) ou poussées seules (titre dans la barre).
class SettingsLayout extends InheritedWidget {
  const SettingsLayout({
    super.key,
    required this.isWide,
    required this.openSection,
    required super.child,
  });

  final bool isWide;

  /// Ouvre une autre catégorie — « Tout voir » du tableau de bord vers
  /// l'historique, par exemple.
  final void Function(String sectionId) openSection;

  static SettingsLayout? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsLayout>();

  @override
  bool updateShouldNotify(SettingsLayout oldWidget) =>
      isWide != oldWidget.isWide;
}

/// Comment une page est montée dans sa catégorie.
///
/// Une catégorie de la navigation peut réunir plusieurs pages : empilées sur
/// un seul défilement (la première porte la page, les suivantes deviennent des
/// sections), ou derrière des onglets. Les pages n'en savent rien : elles
/// construisent toujours un [SettingsPage], et c'est lui qui lit ce cadre.
class SettingsPageFrame extends InheritedWidget {
  /// La page qui porte la catégorie : son titre est celui de la navigation,
  /// [tabs] se place sous le titre et [appended] après ses groupes.
  const SettingsPageFrame({
    super.key,
    required this.title,
    this.tabs,
    this.appended = const [],
    required super.child,
  }) : asSection = false;

  /// Une page posée sous une autre : un intertitre, pas de défilement à elle.
  const SettingsPageFrame.section({super.key, required super.child})
      : title = null,
        tabs = null,
        appended = const [],
        asSection = true;

  final String? title;
  final Widget? tabs;
  final List<Widget> appended;
  final bool asSection;

  static SettingsPageFrame? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsPageFrame>();

  @override
  bool updateShouldNotify(SettingsPageFrame oldWidget) =>
      title != oldWidget.title ||
      tabs != oldWidget.tabs ||
      appended != oldWidget.appended ||
      asSection != oldWidget.asSection;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.description,
    required this.children,
    this.actions = const [],
    this.onRefresh,
  });

  final String title;
  final String description;
  final List<Widget> children;
  final List<Widget> actions;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final frame = SettingsPageFrame.maybeOf(context);
    if (frame != null && frame.asSection) return _section(context);

    final isWide = SettingsLayout.maybeOf(context)?.isWide ?? false;
    final textTheme = Theme.of(context).textTheme;
    final horizontal = isWide ? 48.0 : 20.0;
    final tabs = frame?.tabs;

    final header = Padding(
      padding: EdgeInsets.only(bottom: isWide ? 40 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isWide) ...[
                Text(
                  frame?.title ?? title,
                  style: textTheme.headlineSmall?.copyWith(
                    fontSize: AppType.largeTitle,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (tabs != null) ...[
                tabs,
                SizedBox(height: isWide ? 20 : 16),
              ],
              Text(
                description,
                style: textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.45,
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );

    Widget scroll = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding:
          EdgeInsets.fromLTRB(horizontal, isWide ? 52 : 16, horizontal, 64),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [header, ...children, ...?frame?.appended],
            ),
          ),
        ),
      ],
    );
    if (onRefresh != null) {
      scroll = RefreshIndicator(onRefresh: onRefresh!, child: scroll);
    }
    return scroll;
  }

  /// La page réduite à une section de celle qui la porte : un filet, un
  /// intertitre plus grand que ceux des groupes, la phrase qui dit à quoi elle
  /// sert, puis ses groupes. Le tirer-pour-actualiser appartient à la page
  /// qui défile ; une section garde ses boutons d'action.
  Widget _section(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          const SizedBox(height: 32),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: AppType.title2,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }
}

/// Ouvre une page de réglages par-dessus la catégorie, avec son titre dans la
/// barre : pour ce qu'on ne visite qu'en cas de besoin (le journal, installer
/// l'app ailleurs), qui encombrerait la navigation sans en avoir le poids.
///
/// Un lien de la sous-page vers une catégorie referme d'abord la sous-page.
void pushSettingsSubpage(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
}) {
  final parent = SettingsLayout.maybeOf(context);
  final navigator = Navigator.of(context);
  navigator.push(MaterialPageRoute<void>(
    builder: (routeContext) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(title)),
      body: SettingsLayout(
        isWide: false,
        openSection: (id) {
          navigator.pop();
          parent?.openSection(id);
        },
        child: Builder(builder: builder),
      ),
    ),
  ));
}
