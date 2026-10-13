import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/home_provider.dart';
import '../../../theme/app_colors.dart';
import '../media_review_screen.dart';
import '../widgets/libraries_group.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/tr.dart';

/// Les bibliothèques (manage_settings) et l'indexation (manage_library) :
/// déléguer un scan est sans risque, faire lire un autre dossier au serveur ne
/// l'est pas.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  Future<void> _run(String label, Future<void> Function() action) async {
    try {
      await action();
      if (mounted) showSettingsSnack(context, tr('{0} lancé…', [label]));
    } catch (_) {
      if (mounted) {
        showSettingsSnack(context, tr('Impossible de lancer : {0}', [label]),
            error: true);
      }
    }
  }

  String _progress(int processed, int total, String fallback) =>
      total > 0 ? tr('Progression {0} / {1}', [processed, total]) : fallback;

  Widget _busyOr(bool busy, VoidCallback? onRun) => busy
      ? const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : TextButton(onPressed: onRun, child: Text(tr('Lancer')));

  @override
  Widget build(BuildContext context) {
    final perms = context.watch<AuthProvider>().permissions;
    final home = context.watch<HomeProvider>();

    return SettingsPage(
      title: tr('Bibliothèque'),
      description:
          tr('Les dossiers que le serveur présente, sous le nom que vous leur '
              'donnez, et les tâches qui tiennent le catalogue à jour.'),
      children: [
        if (perms.manageSettings) const LibrariesGroup(),
        if (perms.manageLibrary) ...[
          SettingsGroup(
            title: tr('Analyse'),
            children: [
              SettingsTile(
                icon: Icons.sync_rounded,
                iconColor: AppColors.primary,
                title: tr('Synchroniser la bibliothèque'),
                subtitle: home.isScanning
                    ? tr('Analyse en cours…')
                    : tr('Ajouter les nouveaux fichiers et retirer ceux qui '
                        'ont disparu'),
                showChevron: false,
                trailing: _busyOr(
                  home.isScanning,
                  () => _run(tr('Synchronisation'), home.triggerLibraryScan),
                ),
              ),
              SettingsTile(
                icon: Icons.fact_check_outlined,
                title: tr('Médias à vérifier'),
                subtitle:
                    tr('Films et séries mal identifiés ou aux fiches incomplètes'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MediaReviewScreen()),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: tr('Maintenance'),
            footer:
                tr('Ces tâches tournent en arrière-plan sur le serveur ; '
                    'vous pouvez quitter cette page.'),
            children: [
              SettingsTile(
                icon: Icons.image_outlined,
                title: tr('Compléter les affiches et résumés'),
                subtitle: home.isBackfillingMetadata
                    ? tr('Récupération depuis TMDB…')
                    : tr('Récupérer ce qui manque depuis TMDB'),
                showChevron: false,
                trailing: _busyOr(
                  home.isBackfillingMetadata,
                  () => _run(
                      tr('Mise à jour des affiches'), home.triggerMetadataBackfill),
                ),
              ),
              SettingsTile(
                icon: Icons.manage_search_rounded,
                title: tr('Réidentifier tout le catalogue'),
                subtitle: home.isRedetectingAll
                    ? _progress(home.redetectAllProgress.processed,
                        home.redetectAllProgress.total, tr('Réidentification…'))
                    : tr('Refaire la correspondance TMDB de chaque film et série'),
                showChevron: false,
                trailing: _busyOr(
                  home.isRedetectingAll,
                  () =>
                      _run(tr('Réidentification'), home.triggerRedetectAllMatches),
                ),
              ),
              SettingsTile(
                icon: Icons.subtitles_outlined,
                title: tr('Extraire les sous-titres'),
                subtitle: home.isExtractingSubtitles
                    ? _progress(home.subtitleStats.processed,
                        home.subtitleStats.total, tr('Extraction…'))
                    : tr('Préparer les pistes intégrées pour une lecture immédiate'),
                showChevron: false,
                trailing: _busyOr(
                  home.isExtractingSubtitles,
                  () => _run(tr('Extraction des sous-titres'),
                      home.triggerSubtitleExtract),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
