import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';

import '../../../models/server_activity.dart';
import '../../../theme/app_colors.dart';

/// Les briques des paramètres : une page, des groupes en carte, des lignes.
///
/// Toutes les catégories sont faites des mêmes pièces, pour qu'aucune ne
/// ressemble à un formulaire posé là : un titre, une phrase qui dit à quoi sert
/// la page, puis des groupes nommés dont les lignes se lisent d'un coup d'œil.

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
    final isWide = SettingsLayout.maybeOf(context)?.isWide ?? false;
    final textTheme = Theme.of(context).textTheme;
    final horizontal = isWide ? 48.0 : 20.0;

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
                  title,
                  style: textTheme.headlineSmall?.copyWith(
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 10),
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
              children: [header, ...children],
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
}

/// Un groupe nommé de lignes, dans une carte.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    this.trailing,
    required this.children,
    this.padded = false,
  });

  final String? title;
  final String? footer;
  final Widget? trailing;
  final List<Widget> children;

  /// Pour un contenu libre (formulaire, graphique) plutôt qu'une liste de lignes.
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0 && !padded) {
        rows.add(Divider(
          height: 1,
          thickness: 1,
          indent: 64,
          color: Colors.white.withValues(alpha: 0.06),
        ));
      }
      rows.add(children[i]);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || trailing != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title ?? '',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          Material(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: padded
                    ? const EdgeInsets.all(20)
                    : const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                footer!,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// La pastille d'icône d'une ligne.
class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.icon, {super.key, this.color, this.size = 34});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? AppColors.textSecondary;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.59, color: tint),
    );
  }
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    this.icon,
    this.iconColor,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.showChevron,
  });

  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final bool? showChevron;

  @override
  Widget build(BuildContext context) {
    final chevron = showChevron ?? (onTap != null && trailing == null);
    final titleColor = destructive ? AppColors.error : AppColors.textPrimary;
    return InkWell(
      onTap: onTap,
      focusColor: AppColors.primary.withValues(alpha: 0.16),
      hoverColor: Colors.white.withValues(alpha: 0.03),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: LayoutBuilder(builder: (context, constraints) {
            final stackControl = constraints.maxWidth < 440 &&
                trailing != null &&
                trailing is! Switch;
            return Row(
              children: [
                if (leading != null)
                  leading!
                else if (icon != null)
                  SettingsIcon(
                    icon!,
                    color: destructive ? AppColors.error : iconColor,
                  ),
                if (leading != null || icon != null) const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: titleColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5,
                        ),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                      if (stackControl) ...[
                        const SizedBox(height: 12),
                        trailing!,
                      ],
                    ],
                  ),
                ),
                if (trailing != null && !stackControl) ...[
                  const SizedBox(width: 12),
                  trailing!,
                ],
                if (chevron) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textMuted, size: 20),
                ],
              ],
            );
          }),
        ),
      ),
    );
  }
}

class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      showChevron: false,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// Un choix parmi quelques options, en boutons segmentés sous le libellé.
class SettingsChoiceTile<T> extends StatelessWidget {
  const SettingsChoiceTile({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.footnote,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final String? footnote;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            SettingsIcon(icon!),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final (option, label) in options)
                      ChoiceChip(
                        label: Text(label),
                        selected: value == option,
                        showCheckmark: false,
                        selectedColor: AppColors.primary.withValues(alpha: 0.2),
                        backgroundColor: Colors.transparent,
                        labelStyle: TextStyle(
                          color: value == option
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                        ),
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.1)),
                        onSelected: (_) => onChanged(option),
                      ),
                  ],
                ),
                if (footnote != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    footnote!,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Une petite étiquette de statut.
class SettingsPill extends StatelessWidget {
  const SettingsPill(this.label, {super.key, this.color, this.icon});

  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tint),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: tint,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

Color playMethodColor(PlayMethod method) => switch (method) {
      PlayMethod.direct => AppColors.success,
      PlayMethod.directStream => AppColors.primary,
      PlayMethod.transcode => AppColors.warning,
      PlayMethod.local => AppColors.textSecondary,
    };

/// Un chiffre clé : « 42 h — Temps de visionnage ».
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.hint,
    this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? hint;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? AppColors.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: tint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
              ),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(
              hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }
}

/// Des tuiles de chiffres qui passent de 4 à 2 colonnes selon la largeur.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 640 ? 4 : 2;
        const gap = 12.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      }),
    );
  }
}

/// Une ligne de texte discrète quand un groupe n'a rien à montrer.
class SettingsEmptyNote extends StatelessWidget {
  const SettingsEmptyNote(this.message, {super.key, this.icon});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon ?? Icons.inbox_outlined,
              size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsLoading extends StatelessWidget {
  const SettingsLoading({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
}

enum BannerTone { error, success, info }

class SettingsBanner extends StatelessWidget {
  const SettingsBanner(this.message, {super.key, this.tone = BannerTone.info});

  final String message;
  final BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (tone) {
      BannerTone.error => (AppColors.error, Icons.error_outline_rounded),
      BannerTone.success => (AppColors.success, Icons.check_circle_outline),
      BannerTone.info => (AppColors.primary, Icons.info_outline_rounded),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// Un avatar à l'initiale, teinté d'après le nom pour que deux comptes ne se
/// confondent pas dans une liste.
class UserAvatar extends StatelessWidget {
  const UserAvatar(this.name, {super.key, this.size = 36});

  final String name;
  final double size;

  static const _palette = [
    Color(0xFF0A84FF),
    Color(0xFF30D158),
    Color(0xFFFF9F0A),
    Color(0xFFBF5AF2),
    Color(0xFFFF375F),
    Color(0xFF64D2FF),
  ];

  @override
  Widget build(BuildContext context) {
    final tint = name.isEmpty
        ? AppColors.textMuted
        : _palette[
            name.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tint.withValues(alpha: 0.55), tint.withValues(alpha: 0.25)],
        ),
      ),
      child: Text(
        name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

void showSettingsSnack(BuildContext context, String message,
    {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? AppColors.error : null,
  ));
}

/// Le message du serveur quand il en donne un, sinon [fallback].
String settingsErrorText(Object error, String fallback) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    if (error.response?.statusCode == 404) {
      return 'Ce serveur est trop ancien pour cette fonction. Mettez-le à jour.';
    }
  }
  return fallback;
}

Future<bool> confirmSettingsAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = true,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Annuler'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: destructive
              ? TextButton.styleFrom(foregroundColor: AppColors.error)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// « à l'instant », « il y a 5 min », « hier à 21:04 », « 12/09 à 18:30 ».
String relativeTime(DateTime moment, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final elapsed = reference.difference(moment);
  String clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (elapsed.inSeconds < 60) return 'à l’instant';
  if (elapsed.inMinutes < 60) return 'il y a ${elapsed.inMinutes} min';
  final today = DateTime(reference.year, reference.month, reference.day);
  final day = DateTime(moment.year, moment.month, moment.day);
  if (day == today) return 'aujourd’hui à ${clock(moment)}';
  if (today.difference(day).inDays == 1) return 'hier à ${clock(moment)}';
  if (today.difference(day).inDays < 7) {
    return 'il y a ${today.difference(day).inDays} jours';
  }
  return '${moment.day.toString().padLeft(2, '0')}/${moment.month.toString().padLeft(2, '0')}/${moment.year}';
}

const _weekdays = [
  'lundi',
  'mardi',
  'mercredi',
  'jeudi',
  'vendredi',
  'samedi',
  'dimanche'
];
const _months = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre'
];

/// « lundi 14 septembre ». L'app n'initialise pas les locales d'intl, et un
/// libellé de jour ne justifie pas de le faire.
String formatFrenchDay(DateTime day, {bool capitalize = false}) {
  final label =
      '${_weekdays[day.weekday - 1]} ${day.day} ${_months[day.month - 1]}';
  return capitalize ? label[0].toUpperCase() + label.substring(1) : label;
}

/// « 14 sept. » : une date courte pour les axes de graphique.
String formatShortFrenchDate(DateTime day) {
  final month = _months[day.month - 1];
  return '${day.day} ${month.length > 4 ? '${month.substring(0, 4)}.' : month}';
}

/// « 42 h 10 », « 35 min » : un temps de visionnage.
String formatWatchTime(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours == 0) return '$minutes min';
  if (hours >= 100 || minutes == 0) return '$hours h';
  return '$hours h ${minutes.toString().padLeft(2, '0')}';
}

/// L'icône qui ressemble à l'appareil qu'une application annonce.
IconData deviceIconFor(String client) {
  final c = client.toLowerCase();
  if (c.contains('tv')) return Icons.tv_rounded;
  if (c.contains('android') || c.contains('ios')) {
    return Icons.smartphone_rounded;
  }
  if (c.contains('web')) return Icons.language_rounded;
  if (c.contains('macos')) return Icons.laptop_mac_rounded;
  if (c.contains('windows') || c.contains('linux')) {
    return Icons.desktop_windows_rounded;
  }
  return Icons.devices_other_rounded;
}
