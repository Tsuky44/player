import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_download.dart';
import '../../services/api_client.dart';
import '../../services/update_checker.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_platform.dart';
import '../../utils/external_url.dart';
import 'app_update_dialog.dart';
import 'glass_chrome.dart';

/// Header shortcut pointing at the installer for the machine in front of us.
///
/// Two different jobs behind one button, because the answer to "do I want this
/// file?" is not the same on both sides:
///
///  * on the web it is how a visitor gets the native app in the first place, so
///    it shows as soon as the server published an artifact for their OS;
///  * inside the installed app it would be pointless to re-download the version
///    already running, so it only appears when the server publishes a *newer*
///    one, and it then updates in place — download, install, restart — instead
///    of dropping an installer in the Downloads folder.
///
/// The full list stays in the settings — that is still the way to grab the APK
/// from a desktop, or the portable ZIP.
class AppDownloadButton extends StatefulWidget {
  final double size;

  const AppDownloadButton({super.key, this.size = 34});

  @override
  State<AppDownloadButton> createState() => _AppDownloadButtonState();
}

class _AppDownloadButtonState extends State<AppDownloadButton> {
  AppDownload? _download;
  bool _requested = false;

  /// True when we are offering an upgrade to a running app rather than a first
  /// install from the browser — it changes the icon and the wording.
  bool get _isUpdate => !AppPlatform.isWeb;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;
    _requested = true;
    _load(context.read<ApiClient>());
  }

  /// An older server has no /api/downloads route, and a missing shortcut is
  /// better than an error banner in the header: on failure we stay hidden.
  Future<void> _load(ApiClient api) async {
    try {
      final offered = _isUpdate
          ? await UpdateChecker.findAvailableUpdate(api)
          : pickDownloadForCurrentPlatform(await api.getAppDownloads());
      if (!mounted) return;
      setState(() => _download = offered);
    } catch (_) {
      if (!mounted) return;
      setState(() => _download = null);
    }
  }

  Future<void> _open() async {
    final download = _download;
    if (download == null) return;

    // Installed app: never hand the user a file to deal with — the dialog does
    // the whole thing and relaunches us.
    if (_isUpdate) {
      await showAppUpdateDialog(context, download: download);
      return;
    }

    final url = context.read<ApiClient>().getAppDownloadUrl(download);
    final opened = await openExternalUrl(url);
    if (!mounted || opened) return;
    // Mobile has no way to hand a URL off, so show it for the user to copy.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Téléchargement disponible ici : $url')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final download = _download;
    if (download == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: _tooltip(download),
        child: GlassIconButton(
          size: widget.size,
          onTap: _open,
          child: Icon(
            _isUpdate
                ? Icons.system_update_alt_rounded
                : Icons.download_rounded,
            size: widget.size * 0.5,
            color: _isUpdate ? AppColors.accent : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  String _tooltip(AppDownload download) {
    final parts = <String>[
      if (_isUpdate)
        'Mise à jour disponible'
      else
        'Télécharger ${download.label}',
      if (download.version.isNotEmpty) 'Version ${download.version}',
      if (download.formattedSize.isNotEmpty) download.formattedSize,
    ];
    return parts.join(' · ');
  }
}

