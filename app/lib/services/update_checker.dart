import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_download.dart';
import '../utils/app_platform.dart';
import 'api_client.dart';
import 'app_updater.dart';

/// Shared "is there something newer for us" logic, used both by the manual
/// download button and by [AutoUpdateService] so the two never disagree about
/// what counts as an update.
abstract final class UpdateChecker {
  /// An update to auto-install over the running app, or null when there is
  /// none — no newer artifact, nothing published for this OS, or an artifact
  /// we cannot install over ourselves (Android, the Windows portable ZIP).
  ///
  /// A version we cannot compare (unnamed artifact, unreadable package info)
  /// is treated as "no update" — staying quiet beats nagging about a phantom
  /// release.
  static Future<AppDownload?> findAvailableUpdate(ApiClient api) async {
    if (AppPlatform.isWeb) return null;
    try {
      final match = pickDownloadForCurrentPlatform(await api.getAppDownloads());
      if (match == null) return null;
      if (!AppUpdater.supports(match.platform)) return null;

      final published = parseVersion(match.version);
      if (published == null) return null;

      String current;
      try {
        current = (await PackageInfo.fromPlatform()).version;
      } catch (_) {
        return null;
      }
      final running = parseVersion(current);
      if (running == null) return null;

      return isNewerVersion(published, running) ? match : null;
    } catch (_) {
      return null;
    }
  }
}

/// The artifact matching the OS we run on, or null when nobody published it.
///
/// `windows` (the installer) wins over `windows-portable`: the shortcut is
/// meant to be the no-question path, the ZIP stays in the settings list.
AppDownload? pickDownloadForCurrentPlatform(List<AppDownload> downloads) {
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
/// A build suffix (`1.2.3+7`, `1.2.3-beta`) is dropped: the artifacts are
/// named after the release version, and comparing on it is what decides an
/// update.
List<int>? parseVersion(String raw) {
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

bool isNewerVersion(List<int> candidate, List<int> reference) {
  final length =
      candidate.length > reference.length ? candidate.length : reference.length;
  for (var i = 0; i < length; i++) {
    final a = i < candidate.length ? candidate[i] : 0;
    final b = i < reference.length ? reference[i] : 0;
    if (a != b) return a > b;
  }
  return false;
}
