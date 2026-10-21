import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/tr.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/new_episodes/new_episode_alerts.dart';
import 'settings_ui.dart';

/// Les réglages des notifications : nouveaux épisodes (ADR-0059) et, pour un
/// administrateur, nouvelles demandes (ADR-0077).
///
/// N'est monté que là où [NewEpisodeAlerts.supported] est vrai : un
/// interrupteur sans effet sur un téléviseur serait une promesse non tenue.
class NewEpisodeAlertsGroup extends StatelessWidget {
  const NewEpisodeAlertsGroup({super.key});

  Future<void> _toggle(
    BuildContext context,
    Future<bool> Function(bool) set,
    bool value,
  ) async {
    final granted = await set(value);
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
    // Le serveur ne rend le flux des demandes qu'à `manage_settings` : ailleurs
    // l'interrupteur ne commanderait rien.
    final admin =
        context.watch<AuthProvider>().currentUser?.permissions.manageSettings ??
            false;
    return ListenableBuilder(
      listenable: Listenable.merge(
          [NewEpisodeAlerts.enabled, NewEpisodeAlerts.requestsEnabled]),
      builder: (context, _) => SettingsGroup(
        title: tr('Notifications'),
        children: [
          SettingsSwitchTile(
            icon: Icons.notifications_active_outlined,
            title: tr('Nouveaux épisodes'),
            subtitle:
                tr('Une notification quand un épisode sort pour une série '
                    'que vous suivez, sur tous vos serveurs. L’appareil les '
                    'interroge de temps en temps, même app fermée.'),
            value: NewEpisodeAlerts.enabled.value,
            onChanged: (value) =>
                _toggle(context, NewEpisodeAlerts.setEnabled, value),
          ),
          if (admin)
            SettingsSwitchTile(
              icon: Icons.inbox_outlined,
              title: tr('Nouvelles demandes'),
              subtitle: tr('Une notification quand un compte demande un film '
                  'ou une série, avec son nom et les saisons voulues. '
                  'Réservé aux administrateurs.'),
              value: NewEpisodeAlerts.requestsEnabled.value,
              onChanged: (value) =>
                  _toggle(context, NewEpisodeAlerts.setRequestsEnabled, value),
            ),
        ],
      ),
    );
  }
}
