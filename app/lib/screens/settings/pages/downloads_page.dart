import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/download_manager.dart';
import '../../../services/download_preferences.dart';
import '../../../services/network_status.dart';
import '../../../utils/format.dart';
import '../widgets/settings_ui.dart';

/// Ce que l'appareil rapatrie, et sur quel réseau il a le droit de le faire.
///
/// Des réglages d'appareil, comme le profil de lecture (ADR-0004) : c'est ce
/// téléphone-ci qui a un forfait et ce disque-là qui se remplit, pas le compte.
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final preferences = context.watch<DownloadPreferences>();
    final downloads = context.watch<DownloadManager>();
    final network = context.watch<NetworkStatus>();

    return SettingsPage(
      title: 'Téléchargements',
      description:
          'Ce que cet appareil garde hors ligne, et quand il a le droit de '
          'l’aller chercher. Ces réglages ne changent rien sur vos autres '
          'appareils.',
      children: [
        SettingsGroup(
          title: 'Épisodes suivants',
          footer: switch (preferences.mode) {
            AutoDownloadMode.keepAhead =>
              'Dès qu’un épisode d’une série est téléchargé, l’app garde '
                  '${preferences.keepAhead} épisode'
                  '${preferences.keepAhead > 1 ? 's' : ''} non vu'
                  '${preferences.keepAhead > 1 ? 's' : ''} d’avance sur cet '
                  'appareil. Chaque épisode terminé libère une place, et la '
                  'place se remplit avec le suivant.',
            AutoDownloadMode.wholeShow =>
              'Dès qu’un épisode d’une série est téléchargé, tout ce que le '
                  'serveur a de cette série descend — sauf ce que vous avez '
                  'déjà vu. De quoi remplir un disque : à réserver aux séries '
                  'qu’on emporte.',
            AutoDownloadMode.off =>
              'Rien ne descend sans que vous le demandiez.',
          },
          children: [
            SettingsChoiceTile<AutoDownloadMode>(
              icon: Icons.playlist_add_check_rounded,
              title: 'Téléchargement automatique',
              subtitle:
                  'Ne s’applique qu’aux séries dont vous avez déjà téléchargé '
                  'un épisode. Le premier épisode reste toujours un geste.',
              value: preferences.mode,
              options: const [
                (AutoDownloadMode.keepAhead, 'Garder de l’avance'),
                (AutoDownloadMode.wholeShow, 'Toute la série'),
                (AutoDownloadMode.off, 'Désactivé'),
              ],
              onChanged: preferences.setMode,
            ),
            if (preferences.mode == AutoDownloadMode.keepAhead)
              SettingsChoiceTile<int>(
                icon: Icons.inventory_2_outlined,
                title: 'Épisodes d’avance',
                subtitle:
                    'Combien d’épisodes non vus rester d’avance sur cet '
                    'appareil.',
                value: preferences.keepAhead,
                options: const [
                  (2, '2'),
                  (3, '3'),
                  (4, '4'),
                  (5, '5'),
                  (6, '6'),
                  (8, '8'),
                  (10, '10'),
                ],
                onChanged: preferences.setKeepAhead,
              ),
          ],
        ),
        SettingsGroup(
          title: 'Réseau',
          footer:
              'Un épisode est rapatrié dans sa qualité d’origine, sans '
              'compression : plusieurs gigaoctets, souvent. Un réseau limité, '
              'c’est la 4G comme le partage de connexion d’un autre téléphone. '
              'Ce qui attend un réseau libre repart tout seul dès qu’il y en a '
              'un, sans avoir à rouvrir l’app.',
          children: [
            SettingsChoiceTile<MeteredPolicy>(
              icon: Icons.signal_cellular_alt_rounded,
              title: 'Sur un réseau limité',
              subtitle: _networkLine(network),
              value: preferences.meteredPolicy,
              options: const [
                (MeteredPolicy.ask, 'Demander'),
                (MeteredPolicy.always, 'Télécharger'),
                (MeteredPolicy.never, 'Wi-Fi uniquement'),
              ],
              onChanged: preferences.setMeteredPolicy,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Sur cet appareil',
          children: [
            SettingsTile(
              icon: Icons.download_done_rounded,
              title: 'Médias gardés hors ligne',
              subtitle:
                  '${downloads.downloads.length} média'
                  '${downloads.downloads.length > 1 ? 's' : ''} · '
                  '${formatBytes(downloads.totalBytesOnDisk)}',
              showChevron: false,
              trailing: downloads.downloads.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () => _deleteWatched(context),
                      child: const Text('Retirer les vus'),
                    ),
            ),
          ],
        ),
      ],
    );
  }

  /// Ce que l'app voit du réseau, écrit là où la décision se prend : sans ça,
  /// « Wi-Fi uniquement » est un réglage dont on ne sait pas s'il s'applique.
  static String _networkLine(NetworkStatus network) {
    if (network.isDisconnected) {
      return 'Aucun réseau pour l’instant. Ce qui est en file partira au '
          'retour de la connexion.';
    }
    if (network.isMetered) {
      return network.kind == NetworkKind.mobile
          ? 'Vous êtes en données mobiles.'
          : 'Le réseau actuel est signalé comme limité.';
    }
    return 'Le réseau actuel n’est pas limité.';
  }

  Future<void> _deleteWatched(BuildContext context) async {
    final manager = context.read<DownloadManager>();
    final messenger = ScaffoldMessenger.of(context);
    final deleted = await manager.deleteWatched();
    messenger.showSnackBar(SnackBar(
      content: Text(deleted == 0
          ? 'Aucun média vu à retirer'
          : '$deleted média${deleted > 1 ? 's supprimés' : ' supprimé'}'),
    ));
  }
}
