import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/app_download.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/external_url.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/tr.dart';

class AppsPage extends StatefulWidget {
  const AppsPage({super.key});

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  List<AppDownload>? _downloads;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// An older server has no /api/downloads route: the list simply stays empty.
  Future<void> _load() async {
    try {
      final downloads = await context.read<ApiClient>().getAppDownloads();
      if (mounted) setState(() => _downloads = downloads);
    } catch (_) {
      if (mounted) setState(() => _downloads = const []);
    }
  }

  Future<void> _open(AppDownload download) async {
    final url = context.read<ApiClient>().getAppDownloadUrl(download);
    final opened = await openExternalUrl(url);
    if (!mounted || opened) return;
    // Mobile has no way to hand a URL off, so show it for the user to copy.
    showSettingsSnack(context, tr('Téléchargement disponible ici : {0}', [url]));
  }

  IconData _icon(String platform) => switch (platform) {
        'windows' => Icons.desktop_windows_rounded,
        'windows-portable' => Icons.folder_zip_outlined,
        'macos' => Icons.laptop_mac_rounded,
        'android' => Icons.android_rounded,
        'ios' => Icons.phone_iphone_rounded,
        'tvos' => Icons.tv_rounded,
        _ => Icons.download_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final downloads = _downloads;

    return SettingsPage(
      title: tr('Applications'),
      description:
          tr('Installer Onyx sur un autre appareil. Les fichiers sont '
              'servis directement par votre serveur.'),
      children: [
        SettingsGroup(
          title: tr('Disponibles au téléchargement'),
          children: [
            if (downloads == null)
              const SettingsLoading()
            else if (downloads.isEmpty)
              SettingsEmptyNote(
                  tr('Aucun installeur publié sur ce serveur pour l’instant.'))
            else
              for (final download in downloads)
                SettingsTile(
                  icon: _icon(download.platform),
                  iconColor: AppColors.primary,
                  title: download.label,
                  subtitle: [
                    if (download.version.isNotEmpty)
                      tr('Version {0}', [download.version]),
                    if (download.formattedSize.isNotEmpty)
                      download.formattedSize,
                  ].join(' · '),
                  onTap: () => _open(download),
                  trailing: const Icon(Icons.download_rounded,
                      color: AppColors.textMuted, size: 20),
                ),
          ],
        ),
      ],
    );
  }
}
