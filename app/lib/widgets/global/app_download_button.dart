import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../models/app_download.dart';
import '../../services/api_client.dart';
import '../../services/app_updater.dart';
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
      final match = _pickForCurrentPlatform(await api.getAppDownloads());
      final offered = match == null ? null : await _keepIfOffered(match);
      if (!mounted) return;
      setState(() => _download = offered);
    } catch (_) {
      if (!mounted) return;
      setState(() => _download = null);
    }
  }

  /// Filters out an artifact we should not push at this user: in the installed
  /// app, anything we cannot install over ourselves, and anything that is not
  /// strictly newer than the running build. A version we cannot compare
  /// (unnamed artifact, unreadable package info) is treated as "not an update"
  /// — a silent button beats nagging about a phantom release.
  Future<AppDownload?> _keepIfOffered(AppDownload download) async {
    if (!_isUpdate) return download;
    if (!AppUpdater.supports(download.platform)) return null;

    final published = _parseVersion(download.version);
    if (published == null) return null;

    String current;
    try {
      current = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
    final running = _parseVersion(current);
    if (running == null) return null;

    return _isNewer(published, running) ? download : null;
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

/// The artifact matching the OS we run on, or null when nobody published it.
///
/// `windows` (the installer) wins over `windows-portable`: the shortcut is
/// meant to be the no-question path, the ZIP stays in the settings list.
AppDownload? _pickForCurrentPlatform(List<AppDownload> downloads) {
  final wanted = _currentPlatformKey();
  if (wanted == null) return null;

  AppDownload? fallback;
  for (final download in downloads) {
    if (download.platform == wanted) return download;
    if (wanted == 'windows' && download.platform == 'windows-portable') {
      fallback = download;
    }
  }
  return fallback;
}

/// Platform key as published by the server, or null when we have no installer
/// for it (Linux, iOS). On web every `AppPlatform` predicate is false, so the
/// host OS comes from the framework's own browser detection instead.
String? _currentPlatformKey() {
  if (AppPlatform.isWindows) return 'windows';
  if (AppPlatform.isMacOS) return 'macos';
  if (AppPlatform.isAndroid) return 'android';
  if (!AppPlatform.isWeb) return null;

  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.android:
      return 'android';
    default:
      return null;
  }
}

/// Numeric components of a `1.2.3` version, or null when it is not one.
///
/// A build suffix (`1.2.3+7`, `1.2.3-beta`) is dropped: the artifacts are named
/// after the release version, and comparing on it is what decides an update.
List<int>? _parseVersion(String raw) {
  final trimmed = raw.trim().split(RegExp(r'[+\-]')).first;
  if (trimmed.isEmpty) return null;

  final parts = <int>[];
  for (final segment in trimmed.split('.')) {
    final value = int.tryParse(segment);
    if (value == null) return null;
    parts.add(value);
  }
  return parts.isEmpty ? null : parts;
}

bool _isNewer(List<int> candidate, List<int> reference) {
  final length =
      candidate.length > reference.length ? candidate.length : reference.length;
  for (var i = 0; i < length; i++) {
    final a = i < candidate.length ? candidate[i] : 0;
    final b = i < reference.length ? reference[i] : 0;
    if (a != b) return a > b;
  }
  return false;
}
