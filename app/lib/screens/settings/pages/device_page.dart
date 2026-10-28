import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_image_cache.dart';
import '../../../services/new_episodes/new_episode_alerts.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_mode.dart';
import '../../../utils/app_platform.dart';
import '../../../utils/store_build.dart';
import '../tv_link_scanner_screen.dart';
import 'apps_page.dart';
import 'logs_page.dart';
import '../widgets/about_group.dart';
import '../widgets/lite_mode_tile.dart';
import '../widgets/new_episode_alerts_group.dart';
import '../../../providers/auth_provider.dart';
import '../../../widgets/global/interface_tour/interface_tour.dart';
import '../../../widgets/global/resume_preview/hover_preview_preference.dart';
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

  @override
  Widget build(BuildContext context) {
    final isTv = TvScope.of(context);
    final detected = TvMode.detected ? tr('un téléviseur') : tr('un appareil tactile');
    // Le lien se fait en scannant le code affiché par l'autre écran
    // (téléviseur, navigateur, ordinateur) : il faut une caméra, donc un
    // téléphone.
    final canLinkDevice = AppPlatform.isMobile && !isTv;
    // Une Apple TV n'ouvre pas de lien et ne choisit pas de fichier : ni
    // installer ailleurs, ni publier un installeur n'y a de sens. Un build
    // store ne propose pas d'installeurs non plus (ADR-0046).
    final canInstallElsewhere = !AppPlatform.isTvOS && !StoreBuild.enabled;

    return SettingsPage(
      title: tr('Général'),
      description:
          tr('La langue, l’affichage et les notifications de cet appareil, '
              'les autres appareils à connecter, et de l’aide si quelque '
              'chose ne va pas.'),
      children: [
        SettingsGroup(
          title: tr('Affichage'),
          children: [
            // Sur une Apple TV le mode télécommande est le seul possible :
            // rien à régler (voir [TvMode]).
            if (!AppPlatform.isTvOS)
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
            const LiteModeTile(),
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
        if (NewEpisodeAlerts.supported) const NewEpisodeAlertsGroup(),
        // Hors ligne il n'y a que les téléchargements à l'écran : la
        // présentation n'aurait rien de ce qu'elle décrit à montrer.
        if (!context.watch<AuthProvider>().isOfflineSession)
          SettingsGroup(
            title: tr('Interface'),
            children: [
              SettingsTile(
                icon: Icons.explore_outlined,
                title: tr('Revoir la présentation'),
                subtitle: tr('Rejoue le tour de l’accueil et de la '
                    'navigation.'),
                onTap: () {
                  Navigator.of(context, rootNavigator: true)
                      .popUntil((route) => route.isFirst);
                  InterfaceTourReplay.request();
                },
              ),
              if (HoverPreviewPreference.supported && !isTv)
                SettingsSwitchTile(
                  icon: Icons.slideshow_rounded,
                  title: tr('Aperçu au survol'),
                  subtitle: tr('Laisser la souris sur une carte de « Reprendre » '
                      'l’agrandit avec des images de là où vous vous êtes '
                      'arrêté et le résumé.'),
                  value: HoverPreviewPreference.enabled,
                  onChanged: (value) async {
                    await HoverPreviewPreference.setEnabled(value);
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
        if (canLinkDevice || canInstallElsewhere)
          SettingsGroup(
            title: tr('Autres appareils'),
            children: [
              if (canLinkDevice)
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
              if (canInstallElsewhere)
                SettingsTile(
                  icon: Icons.download_for_offline_rounded,
                  title: tr('Installer Onyx sur un autre appareil'),
                  subtitle: tr('Les installeurs servis par votre serveur.'),
                  onTap: () => pushSettingsSubpage(
                    context,
                    title: tr('Applications'),
                    builder: (_) => const AppsPage(),
                  ),
                ),
            ],
          ),
        if (!AppPlatform.isWeb)
          SettingsGroup(
            title: tr('Stockage'),
            // Une Apple TV n'a pas de catégorie Téléchargements où renvoyer.
            footer: AppPlatform.isTvOS
                ? null
                : tr('Les films et épisodes téléchargés se gèrent dans '
                    'Téléchargements.'),
            children: [
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
        SettingsGroup(
          title: tr('Aide'),
          children: [
            SettingsTile(
              icon: Icons.receipt_long_rounded,
              title: tr('Journal'),
              subtitle: tr('Journaux de l’app et des lectures, pour comprendre '
                  'une erreur'),
              onTap: () => pushSettingsSubpage(
                context,
                title: tr('Journal'),
                builder: (_) => const LogsPage(),
              ),
            ),
          ],
        ),
        const AboutGroup(),
      ],
    );
  }
}
