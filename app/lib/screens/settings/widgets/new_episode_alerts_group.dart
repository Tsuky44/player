import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../services/new_episodes/new_episode_alerts.dart';
import 'settings_ui.dart';

/// Le réglage des notifications de nouveaux épisodes (ADR-0059).
///
/// N'est monté que là où [NewEpisodeAlerts.supported] est vrai : un
/// interrupteur sans effet sur un téléviseur serait une promesse non tenue.
class NewEpisodeAlertsGroup extends StatelessWidget {
  const NewEpisodeAlertsGroup({super.key});

  Future<void> _toggle(BuildContext context, bool value) async {
    final granted = await NewEpisodeAlerts.setEnabled(value);
    if (granted || !context.mounted) return;
    showSettingsSnack(
      context,
      tr('Les notifications d’Onyx sont bloquées dans les réglages du '
          'système.'),
      error: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: NewEpisodeAlerts.enabled,
      builder: (context, enabled, _) => SettingsGroup(
        title: tr('Notifications'),
        children: [
          SettingsSwitchTile(
            icon: Icons.notifications_active_outlined,
            title: tr('Nouveaux épisodes'),
            subtitle:
                tr('Une notification quand un épisode sort pour une série '
                    'que vous suivez, sur tous vos serveurs. L’appareil les '
                    'interroge de temps en temps, même app fermée.'),
            value: enabled,
            onChanged: (value) => _toggle(context, value),
          ),
        ],
      ),
    );
  }
}
