import 'package:flutter/material.dart';

import '../../../services/app_image_cache.dart';
import '../../../services/download_manager.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_mode.dart';
import '../../../utils/app_platform.dart';
import '../../../utils/format.dart';
import '../tv_link_scanner_screen.dart';
import '../widgets/about_group.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/app_language.dart';
import '../../../l10n/tr.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({super.key});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  bool _clearingCache = false;

  Future<void> _clearImageCache() async {
    setState(() => _clearingCache = true);
    try {
      await AppImageCache.manager.emptyCache();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (mounted) showSettingsSnack(context, tr('Cache des images vidé.'));
    } catch (_) {
      if (mounted) {
        showSettingsSnack(context, tr('Impossible de vider le cache.'),
            error: true);
      }
    }
    if (mounted) setState(() => _clearingCache = false);
  }

  Future<void> _deleteWatchedDownloads() async {
    final confirmed = await confirmSettingsAction(
      context,
      title: tr('Supprimer les téléchargements vus ?'),
      message:
          tr('Les films et épisodes déjà regardés jusqu’au bout sont '
              'retirés de cet appareil.'),
      confirmLabel: tr('Supprimer'),
    );
    if (!confirmed || !mounted) return;
    final removed = await DownloadManager.instance.deleteWatched();
    if (!mounted) return;
    setState(() {});
    showSettingsSnack(
      context,
      removed == 0
          ? tr('Aucun téléchargement vu à supprimer.')
          : tr('{0} téléchargement{1} supprimé{2}.', [removed, removed > 1 ? 's' : '', removed > 1 ? 's' : '']),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = TvScope.of(context);
    final downloads = DownloadManager.instance;
    final detected = TvMode.detected ? tr('un téléviseur') : tr('un appareil tactile');

    return SettingsPage(
      title: tr('Cet appareil'),
      description:
          tr('Ce qui ne concerne que cet appareil : son mode d’affichage, '
              'le téléviseur à connecter, et ce qu’il garde en mémoire.'),
      children: [
        // Sur une Apple TV le mode télécommande est le seul possible : rien à
        // régler (voir [TvMode]).
        if (!AppPlatform.isTvOS)
          SettingsGroup(
            title: tr('Affichage'),
            children: [
              SettingsChoiceTile<TvModePreference>(
                icon: Icons.settings_remote_rounded,
                title: tr('Mode télécommande'),
                subtitle:
                    tr('Interface pensée pour un téléviseur et une '
                        'télécommande. Cet appareil est détecté comme {0}.', [detected]),
                value: TvMode.preference,
                options: [
                  (TvModePreference.auto, tr('Auto')),
                  (TvModePreference.on, tr('Activé')),
                  (TvModePreference.off, tr('Désactivé')),
                ],
                onChanged: (value) async {
                  await TvMode.setPreference(value);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        SettingsGroup(
          title: tr('Langue'),
          children: [
            SettingsChoiceTile<AppLanguage?>(
              icon: Icons.translate_rounded,
              title: tr('Langue de l’interface'),
              subtitle: tr('« Auto » suit la langue de cet appareil.'),
              value: AppLanguage.chosen,
              options: [
                (null, tr('Auto')),
                for (final language in AppLanguage.values)
                  (language, language.nativeName),
              ],
              onChanged: AppLanguage.choose,
            ),
          ],
        ),
        // Le lien se fait en scannant le code affiché par l'autre écran
        // (téléviseur, navigateur, ordinateur) : il faut une caméra, donc un
        // téléphone.
        if (AppPlatform.isMobile && !isTv)
          SettingsGroup(
            title: tr('Autres appareils'),
            children: [
              SettingsTile(
                icon: Icons.qr_code_scanner_rounded,
                iconColor: AppColors.primary,
                title: tr('Connecter un appareil'),
                subtitle:
                    tr('Scannez le code QR affiché par Onyx sur un '
                        'téléviseur, un ordinateur ou un navigateur : il se '
                        'connecte à votre compte, sans mot de passe.'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const TvLinkScannerScreen()),
                ),
              ),
            ],
          ),
        if (!AppPlatform.isWeb && downloads.isSupported)
          SettingsGroup(
            title: tr('Stockage'),
            children: [
              SettingsTile(
                icon: Icons.download_done_rounded,
                title: tr('Téléchargements hors ligne'),
                subtitle:
                    tr('{0} média{1} · {2}', [downloads.downloads.length, downloads.downloads.length > 1 ? 's' : '', formatBytes(downloads.totalBytesOnDisk)]),
                showChevron: false,
                trailing: downloads.downloads.isEmpty
                    ? null
                    : TextButton(
                        onPressed: _deleteWatchedDownloads,
                        child: Text(tr('Retirer les vus')),
                      ),
              ),
              SettingsTile(
                icon: Icons.image_outlined,
                title: tr('Cache des images'),
                subtitle:
                    tr('Affiches et fonds gardés sur l’appareil pour '
                        's’afficher sans attendre. Ils seront retéléchargés.'),
                showChevron: false,
                trailing: _clearingCache
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _clearImageCache,
                        child: Text(tr('Vider')),
                      ),
              ),
            ],
          ),
        const AboutGroup(),
      ],
    );
  }
}
