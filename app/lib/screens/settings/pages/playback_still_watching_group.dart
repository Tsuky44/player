import 'package:flutter/material.dart';

import '../../../models/still_watching_settings.dart';
import '../../../theme/app_colors.dart';
import '../widgets/settings_dropdown_label.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/tr.dart';

/// Le groupe « Vous regardez encore ? » de la page Lecture (ADR-0045).
///
/// Passif : il affiche [value] et rend le réglage modifié par [onChanged].
/// Les lignes de détail n'existent que quand elles servent — le nombre
/// d'épisodes et la plage quand la question est activée, les heures quand une
/// plage est choisie.
class StillWatchingSettingsGroup extends StatelessWidget {
  const StillWatchingSettingsGroup({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final StillWatchingSettings value;
  final ValueChanged<StillWatchingSettings> onChanged;

  /// Au-delà de cinq, la question arrive trop tard pour celui qui dort.
  static const List<int> _episodeChoices = [1, 2, 3, 4, 5];

  @override
  Widget build(BuildContext context) {
    final episodeChoices = {..._episodeChoices, value.episodes}.toList()
      ..sort();

    return SettingsGroup(
      title: tr('Vous regardez encore ?'),
      footer: value.enabled
          ? tr('Le moindre geste — souris, touche, télécommande, doigt sur '
              'l’écran — remet le compte à zéro.')
          : null,
      children: [
        SettingsSwitchTile(
          icon: Icons.bedtime_outlined,
          title: tr('Demander si vous regardez encore'),
          subtitle:
              tr('Quand plusieurs épisodes s’enchaînent sans que vous '
                  'touchiez au lecteur, la lecture se met en pause et attend '
                  'votre réponse au lieu de lancer le suivant.'),
          value: value.enabled,
          onChanged: (enabled) => onChanged(value.copyWith(enabled: enabled)),
        ),
        if (value.enabled) ...[
          SettingsChoiceTile<int>(
            icon: Icons.playlist_play_rounded,
            title: tr('Épisodes sans intervention'),
            subtitle: tr('La question est posée à la fin du dernier.'),
            value: value.episodes,
            options: [
              for (final count in episodeChoices) (count, '$count'),
            ],
            onChanged: (episodes) =>
                onChanged(value.copyWith(episodes: episodes)),
          ),
          SettingsChoiceTile<bool>(
            icon: Icons.schedule_rounded,
            title: tr('Quand la poser'),
            value: value.allDay,
            options: [
              (true, tr('Toute la journée')),
              (false, tr('Sur une plage horaire')),
            ],
            onChanged: (allDay) => onChanged(value.copyWith(
              fromMinute: allDay
                  ? StillWatchingSettings.allDayMinute
                  : StillWatchingSettings.defaultFromMinute,
              untilMinute: allDay
                  ? StillWatchingSettings.allDayMinute
                  : StillWatchingSettings.defaultUntilMinute,
            )),
          ),
          if (!value.allDay)
            SettingsTile(
              icon: Icons.nightlight_outlined,
              title: tr('Plage horaire'),
              subtitle: tr('À l’heure de l’appareil qui lit. En dehors, les épisodes '
                  's’enchaînent sans question.'),
              showChevron: false,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _HourMenu(
                    tooltip: tr('Début de la plage'),
                    minute: value.fromMinute,
                    excluded: value.untilMinute,
                    onSelected: (minute) =>
                        onChanged(value.copyWith(fromMinute: minute)),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('à',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                  _HourMenu(
                    tooltip: tr('Fin de la plage'),
                    minute: value.untilMinute,
                    excluded: value.fromMinute,
                    onSelected: (minute) =>
                        onChanged(value.copyWith(untilMinute: minute)),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// « 22:00 », pour une minute depuis minuit.
String _formatMinuteOfDay(int minute) {
  final hours = (minute ~/ 60).toString().padLeft(2, '0');
  final minutes = (minute % 60).toString().padLeft(2, '0');
  return '$hours:$minutes';
}

/// Le choix d'une heure ronde. [excluded] est l'autre borne : deux bornes
/// égales ne décriraient aucune plage, alors l'heure n'est pas proposée.
class _HourMenu extends StatelessWidget {
  const _HourMenu({
    required this.tooltip,
    required this.minute,
    required this.excluded,
    required this.onSelected,
  });

  final String tooltip;
  final int minute;
  final int excluded;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: tooltip,
      color: AppColors.surfaceElevated,
      initialValue: minute,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (var hour = 0; hour < 24; hour++)
          if (hour * 60 != excluded)
            PopupMenuItem<int>(
              value: hour * 60,
              child: Text(_formatMinuteOfDay(hour * 60)),
            ),
      ],
      child: SettingsDropdownLabel(_formatMinuteOfDay(minute)),
    );
  }
}
