import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'android_apk_installer.dart';

/// Native in-place updater — see `app_updater.dart`.
///
/// On macOS and Windows the whole point is that the user never handles a
/// file: we fetch the same artifact the download page serves, unpack it while
/// the app keeps running, and hand over to something outside our process that
/// performs the swap in the seconds after we quit — nothing can overwrite a
/// running .app bundle or a locked .exe from within. On macOS that is a small
/// shell script; on Windows it is `onyx-updater.exe`, shipped next to the app
/// (see `windows/updater/` and ADR-0030).
///
/// Android has no such swap to perform — the APK *is* the installable
/// artifact — so it skips straight to handing it to the system installer (see
/// `android_apk_installer.dart`). That installer's confirmation screen is the
/// OS's own and cannot be skipped, which is also why the app is never quit on
/// that path: unlike the desktop helper, nothing here is waiting on our PID.

/// Something went wrong in a way the user can act on — the message is shown
/// as-is in the update dialog.
class UpdateException implements Exception {
  final String message;

  UpdateException(this.message);

  @override
  String toString() => message;
}

/// An update already unpacked on disk. Everything slow and everything that can
/// fail has happened by the time one of these exists: applying it is only a
/// matter of quitting and letting the helper run — or, on Android, handing the
/// APK to the system installer.
class PreparedUpdate {
  /// The macOS helper script that waits for our exit and swaps the app, the
  /// signed ZIP on Windows, or the downloaded APK on Android — which one the
  /// platform and [_isAndroidApk] say.
  final String _launcherPath;

  /// Temp directory holding the download and the staged app, removed by the
  /// helper once the swap succeeded (macOS), by [AppUpdater.purgeStaleWorkDirs]
  /// on the next launch (Windows, whose updater only copies the ZIP out), or by
  /// [discard] directly (Android, which has no helper to do it).
  final String _workDir;

  final bool _isAndroidApk;

  const PreparedUpdate._(this._launcherPath, this._workDir)
      : _isAndroidApk = false;

  const PreparedUpdate._androidApk(String apkPath, this._workDir)
      : _launcherPath = apkPath,
        _isAndroidApk = true;

  /// Best-effort cleanup for an update the user decided not to apply.
  Future<void> discard() async {
    try {
      await Directory(_workDir).delete(recursive: true);
    } catch (_) {}
  }
}

abstract final class AppUpdater {
  /// True when we can install this artifact over the running app.
  ///
  /// Keyed on the server's platform string. On Windows that is
  /// `windows-portable`: the signed ZIP is what `onyx-updater.exe` applies,
  /// the installer only serves first installs. An install without the updater
  /// next to it (older than ADR-0030) cannot apply it.
  static bool supports(String platform) {
    if (Platform.isMacOS) return platform == 'macos';
    if (Platform.isWindows) {
      return platform == 'windows-portable' &&
          File(_windowsUpdaterPath()).existsSync();
    }
    if (Platform.isAndroid) return platform == 'android';
    return false;
  }

  /// Directory the download and the staged app live in until the swap.
  ///
  /// A path rather than a `Directory`, so the same signature type-checks
  /// against the web stub, which has no `dart:io`.
  static Future<String> createWorkDir() async {
    final dir = await (await _workDirParent()).createTemp('onyx-update-');
    return dir.path;
  }

  /// Where work directories are created.
  ///
  /// Sur Android, `Directory.systemTemp` n'est pas `cache/` mais `code_cache/`
  /// (le moteur Flutter lui passe `getCodeCacheDir()`), que le FileProvider de
  /// `res/xml/file_paths.xml` n'expose pas : `getUriForFile` refusait l'APK et
  /// l'installeur ne s'ouvrait jamais, sans un mot. `getTemporaryDirectory()`
  /// est, lui, le vrai `getCacheDir()`.
  static Future<Directory> _workDirParent() async {
    if (Platform.isAndroid) return getTemporaryDirectory();
    return Directory.systemTemp;
  }

  /// Drops a scratch directory whose update will never be applied — a cancelled
  /// download, a failed unpack. Best effort: a leftover in the system temp
  /// directory is not worth an error path.
  static void discardWorkDir(String path) {
    Directory(path).delete(recursive: true).ignore();
  }

  /// Removes what an update applied in a previous session left in the temp
  /// directory. On Windows nothing else does: the updater copies the ZIP out
  /// and never touches our temp directory, so the app it relaunches cleans
  /// up. Android non plus : l'installeur système lit l'APK sans jamais le
  /// supprimer, et la nouvelle version démarre avec lui encore dans `cache/`.
  /// Best effort — a file still locked is simply retried on the next launch.
  static Future<void> purgeStaleWorkDirs() async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    try {
      final parent = await _workDirParent();
      await for (final entry in parent.list(followLinks: false)) {
        final name = entry.path.split(Platform.pathSeparator).last;
        // Also catches `onyx-update-cleanup-*.cmd`, which the batch-based
        // updater of earlier versions left behind.
        if (!name.startsWith('onyx-update-')) continue;
        entry.delete(recursive: true).ignore();
      }
    } catch (_) {}
  }

  /// Unpacks [archivePath] and writes the helper that will apply it.
  ///
  /// Throws [UpdateException] with a user-facing message when the update cannot
  /// be applied — a bundle we do not own, a DMG without an app inside, a
  /// truncated download.
  static Future<PreparedUpdate> prepare({
    required String archivePath,
    required String workDir,
  }) async {
    if (Platform.isAndroid) return _prepareAndroid(archivePath, workDir);
    if (Platform.isMacOS) return _prepareMacOS(archivePath, workDir);
    if (Platform.isWindows) return _prepareWindows(archivePath, workDir);
    throw UpdateException(
      'La mise à jour automatique n’est pas disponible sur cette plateforme.',
    );
  }

  /// Hands the update over and, on desktop, quits.
  ///
  /// On macOS and Windows this never returns once the handoff succeeded: the
  /// helper is already waiting on our PID, and staying alive would only make
  /// it wait longer. On Android the system installer takes over the screen on
  /// its own — the app is not quit, because cancelling that screen must leave
  /// a working app behind, not a process that already exited.
  static Future<void> applyAndRestart(PreparedUpdate update) async {
    if (update._isAndroidApk) {
      if (!await AndroidApkInstaller.install(update._launcherPath)) {
        throw UpdateException(
          'L’installeur Android n’a pas pu s’ouvrir. Réessayez, ou installez '
          'l’APK depuis la page de téléchargement.',
        );
      }
      return;
    }

    if (Platform.isWindows) {
      // A GUI executable: no console flashes, and the app it relaunches has
      // no console to attach to either.
      await Process.start(
        _windowsUpdaterPath(),
        ['apply', '--package', update._launcherPath, '--pid', '$pid'],
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        '/bin/sh',
        [update._launcherPath],
        mode: ProcessStartMode.detached,
      );
    }

    // Give the detached helper a moment to reach its wait loop before the PID
    // it watches disappears.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }
}

// -----------------------------------------------------------------------------
// Android
// -----------------------------------------------------------------------------

/// Nothing to unpack — the download *is* the installable artifact. The only
/// thing worth failing early on is the install permission, which the system
/// picker for "allow installs from this source" needs before the installer
/// will even open: better to send the user there now, with an explanation,
/// than to have the confirmation screen silently fail to appear later.
Future<PreparedUpdate> _prepareAndroid(String apkPath, String workDir) async {
  if (!await AndroidApkInstaller.canInstallPackages()) {
    await AndroidApkInstaller.openInstallPermissionSettings();
    throw UpdateException(
      'Autorisez Onyx à installer des applications dans l’écran qui vient '
      'de s’ouvrir, puis réessayez.',
    );
  }
  return PreparedUpdate._androidApk(apkPath, workDir);
}

// -----------------------------------------------------------------------------
// macOS
// -----------------------------------------------------------------------------

/// Mounts the DMG, copies the bundle out of it, and unmounts it right away so
/// nothing is left attached if the user postpones the restart for hours.
Future<PreparedUpdate> _prepareMacOS(String dmgPath, String workDir) async {
  final target = _currentMacOSBundle();
  await _assertSwappable(Directory(target).parent);

  final mountPoint = '$workDir/mnt';
  await Directory(mountPoint).create(recursive: true);

  final attach = await Process.run('hdiutil', [
    'attach',
    dmgPath,
    '-mountpoint',
    mountPoint,
    '-nobrowse',
    '-noautoopen',
    '-quiet',
  ]);
  if (attach.exitCode != 0) {
    throw UpdateException('Image disque illisible (${attach.stderr}).');
  }

  final staged = '$workDir/staged/Onyx.app';
  try {
    final source = await _findAppBundle(Directory(mountPoint));
    if (source == null) {
      throw UpdateException('Aucune application trouvée dans l’image disque.');
    }
    await Directory('$workDir/staged').create(recursive: true);
    final copy = await Process.run('ditto', [source, staged]);
    if (copy.exitCode != 0) {
      throw UpdateException('Copie de la mise à jour impossible.');
    }
  } finally {
    // -force: the copy may have left the volume busy for a moment.
    await Process.run('hdiutil', ['detach', mountPoint, '-force', '-quiet']);
  }

  final script = File('$workDir/apply-update.sh');
  await script.writeAsString(_macOSLauncher(
    pid: pid,
    staged: staged,
    target: target,
    workDir: workDir,
  ));
  return PreparedUpdate._(script.path, workDir);
}

/// `/Applications/Onyx.app` for an executable at
/// `/Applications/Onyx.app/Contents/MacOS/onyx`.
String _currentMacOSBundle() {
  final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
  if (!bundle.endsWith('.app')) {
    throw UpdateException(
      'Onyx ne tourne pas depuis une application installée — '
      'mise à jour automatique impossible.',
    );
  }
  return bundle;
}

Future<String?> _findAppBundle(Directory volume) async {
  await for (final entry in volume.list(followLinks: false)) {
    if (entry is Directory && entry.path.endsWith('.app')) return entry.path;
  }
  return null;
}

/// Fails early when the app lives somewhere we cannot write — a bundle owned by
/// another user, or a read-only volume. Better here than after a 150 MB
/// download, and far better than half-way through the swap.
Future<void> _assertSwappable(Directory parent) async {
  final probe = File('${parent.path}/.onyx-update-probe');
  try {
    await probe.writeAsString('');
    await probe.delete();
  } catch (_) {
    throw UpdateException(
      'Onyx n’a pas les droits d’écriture sur ${parent.path}. '
      'Déplacez l’app dans votre dossier Applications ou mettez à jour '
      'manuellement.',
    );
  }
}

/// Swap script. The old bundle is moved aside rather than deleted, so a failed
/// copy can be rolled back instead of leaving the machine with no app at all.
String _macOSLauncher({
  required int pid,
  required String staged,
  required String target,
  required String workDir,
}) {
  final p = _shellQuote(staged);
  final t = _shellQuote(target);
  final w = _shellQuote(workDir);
  return '''
#!/bin/sh
# Généré par Onyx — applique la mise à jour dès que l'app est fermée.
i=0
while kill -0 $pid 2>/dev/null; do
  sleep 0.2
  i=\$((i + 1))
  [ \$i -gt 300 ] && exit 1
done
sleep 0.5

backup=$t.old
rm -rf "\$backup"
mv $t "\$backup" || exit 1

if ditto $p $t; then
  xattr -dr com.apple.quarantine $t 2>/dev/null
  rm -rf "\$backup"
  rm -rf $w
else
  rm -rf $t
  mv "\$backup" $t
fi

open $t
''';
}

// -----------------------------------------------------------------------------
// Windows
// -----------------------------------------------------------------------------

/// `onyx-updater.exe`, next to `app.exe`: `flutter build windows` puts it
/// there (windows/CMakeLists.txt), so both the installer and the ZIP carry it.
String _windowsUpdaterPath() =>
    '${File(Platform.resolvedExecutable).parent.path}\\onyx-updater.exe';

/// Nothing to unpack here: the updater verifies the ZIP's signature, extracts
/// it and swaps the files itself, showing its own small window meanwhile, then
/// relaunches the app. It goes through the `OnyxUpdater` service when the app
/// lives in Program Files, so updating never asks for admin rights.
///
/// This used to run the Inno installer from a generated `.cmd` helper, which
/// left two console windows behind — `start` runs a batch file under
/// `cmd /K` — and relaunched the app attached to one of them, so closing it
/// closed Onyx.
Future<PreparedUpdate> _prepareWindows(String zipPath, String workDir) async {
  if (!File(_windowsUpdaterPath()).existsSync()) {
    throw UpdateException(
      'Programme de mise à jour introuvable. Réinstallez Onyx une fois '
      'depuis la page de téléchargement.',
    );
  }
  return PreparedUpdate._(zipPath, workDir);
}

// -----------------------------------------------------------------------------
// Quoting
// -----------------------------------------------------------------------------

/// The macOS launcher is generated text, so a path carrying the shell's own
/// quote character would break out of the string. Temp dirs and install paths never
/// contain one; refusing is the safe answer if it ever happens.
String _shellQuote(String path) {
  if (path.contains("'") || path.contains('\n')) {
    throw UpdateException('Chemin non supporté pour la mise à jour : $path');
  }
  return "'$path'";
}
