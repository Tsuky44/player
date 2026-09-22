import 'package:flutter/material.dart';

import '../../../services/app_image_cache.dart';
import '../../../services/client_identity.dart';
import '../../../services/download_manager.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_mode.dart';
import '../../../utils/app_platform.dart';
import '../../../utils/format.dart';
import '../tv_link_scanner_screen.dart';
import '../widgets/settings_ui.dart';

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
      if (mounted) showSettingsSnack(context, 'Cache des images vidé.');
    } catch (_) {
      if (mounted) {
        showSettingsSnack(context, 'Impossible de vider le cache.',
            error: true);
      }
    }
    if (mounted) setState(() => _clearingCache = false);
  }

  Future<void> _deleteWatchedDownloads() async {
    final confirmed = await confirmSettingsAction(
      context,
      title: 'Supprimer les téléchargements vus ?',
      message:
          'Les films et épisodes déjà regardés jusqu’au bout sont retirés de cet appareil.',
      confirmLabel: 'Supprimer',
    );
    if (!confirmed || !mounted) return;
    final removed = await DownloadManager.instance.deleteWatched();
    if (!mounted) return;
    setState(() {});
    showSettingsSnack(
      context,
      removed == 0
          ? 'Aucun téléchargement vu à supprimer.'
          : '$removed téléchargement${removed > 1 ? 's' : ''} supprimé${removed > 1 ? 's' : ''}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = TvScope.of(context);
    final downloads = DownloadManager.instance;
    final detected = TvMode.detected ? 'un téléviseur' : 'un appareil tactile';

    return SettingsPage(
      title: 'Cet appareil',
      description:
          'Ce qui ne concerne que cet appareil : son mode d’affichage, le téléviseur à connecter, et ce qu’il garde en mémoire.',
      children: [
        // Sur une Apple TV le mode télécommande est le seul possible : rien à
        // régler (voir [TvMode]).
        if (!AppPlatform.isTvOS)
          SettingsGroup(
            title: 'Affichage',
            children: [
              SettingsChoiceTile<TvModePreference>(
                icon: Icons.settings_remote_rounded,
                title: 'Mode télécommande',
                subtitle:
                    'Interface pensée pour un téléviseur et une télécommande. Cet appareil est détecté comme $detected.',
                value: TvMode.preference,
                options: const [
                  (TvModePreference.auto, 'Auto'),
                  (TvModePreference.on, 'Activé'),
                  (TvModePreference.off, 'Désactivé'),
                ],
                onChanged: (value) async {
                  await TvMode.setPreference(value);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        // Le lien se fait en scannant le code affiché par l'autre écran
        // (téléviseur, navigateur, ordinateur) : il faut une caméra, donc un
        // téléphone.
        if (AppPlatform.isMobile && !isTv)
          SettingsGroup(
            title: 'Autres appareils',
            children: [
              SettingsTile(
                icon: Icons.qr_code_scanner_rounded,
                iconColor: AppColors.primary,
                title: 'Connecter un appareil',
                subtitle:
                    'Scannez le code QR affiché par Onyx sur un téléviseur, un ordinateur ou un navigateur : il se connecte à votre compte, sans mot de passe.',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const TvLinkScannerScreen()),
                ),
              ),
            ],
          ),
        if (!AppPlatform.isWeb && downloads.isSupported)
          SettingsGroup(
            title: 'Stockage',
            children: [
              SettingsTile(
                icon: Icons.download_done_rounded,
                title: 'Téléchargements hors ligne',
                subtitle:
                    '${downloads.downloads.length} média${downloads.downloads.length > 1 ? 's' : ''} · ${formatBytes(downloads.totalBytesOnDisk)}',
                showChevron: false,
                trailing: downloads.downloads.isEmpty
                    ? null
                    : TextButton(
                        onPressed: _deleteWatchedDownloads,
                        child: const Text('Retirer les vus'),
                      ),
              ),
              SettingsTile(
                icon: Icons.image_outlined,
                title: 'Cache des images',
                subtitle:
                    'Affiches et fonds gardés sur l’appareil pour s’afficher sans attendre. Ils seront retéléchargés.',
                showChevron: false,
                trailing: _clearingCache
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _clearImageCache,
                        child: const Text('Vider'),
                      ),
              ),
            ],
          ),
        SettingsGroup(
          title: 'À propos',
          children: [
            SettingsTile(
              icon: Icons.info_outline_rounded,
              title: 'Onyx ${ClientIdentity.version}',
              subtitle: ClientIdentity.platform,
              showChevron: false,
            ),
            SettingsTile(
              icon: Icons.badge_outlined,
              title: ClientIdentity.deviceName,
              subtitle:
                  'Le nom sous lequel cet appareil apparaît dans la liste des appareils connectés.',
              showChevron: false,
            ),
          ],
        ),
      ],
    );
  }
}
