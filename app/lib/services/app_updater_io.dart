import 'dart:io';

import 'android_apk_installer.dart';

/// Native in-place updater — see `app_updater.dart`.
///
/// On macOS and Windows the whole point is that the user never handles a
/// file: we fetch the same artifact the download page serves, unpack it while
/// the app keeps running, and leave a small helper script behind that
/// performs the swap in the two seconds after we quit — that last part has to
/// happen outside our process, since nothing can overwrite a running .app
/// bundle or a locked .exe from within.
///
/// Android has no such swap to perform — the APK *is* the installable
/// artifact — so it skips straight to handing it to the system installer (see
/// `android_apk_installer.dart`). That installer's confirmation screen is the
/// OS's own and cannot be skipped, which is also why the app is never quit on
/// that path: unlike the desktop helper, nothing here is waiting on our PID.
///
/// The Windows portable ZIP has no install step at all, so it simply reports
/// unsupported and the caller hides its button.

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
  /// The desktop helper script that waits for our exit and swaps the app, or
  /// the downloaded APK's own path on Android — which one [_isAndroidApk]
  /// says.
  final String _launcherPath;

  /// Temp directory holding the download and the staged app, removed by the
  /// helper once the swap succeeded (desktop), or by [discard] directly
  /// (Android, which has no helper to do it).
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
  /// Keyed on the server's platform string so `windows-portable` — a ZIP with
  /// no installer — is correctly rejected on a Windows host.
  static bool supports(String platform) {
    if (Platform.isMacOS) return platform == 'macos';
    if (Platform.isWindows) return platform == 'windows';
    if (Platform.isAndroid) return platform == 'android';
    return false;
  }

  /// Directory the download and the staged app live in until the swap.
  ///
  /// A path rather than a `Directory`, so the same signature type-checks
  /// against the web stub, which has no `dart:io`.
  static Future<String> createWorkDir() async {
    final dir = await Directory.systemTemp.createTemp('onyx-update-');
    return dir.path;
  }

  /// Drops a scratch directory whose update will never be applied — a cancelled
  /// download, a failed unpack. Best effort: a leftover in the system temp
  /// directory is not worth an error path.
  static void discardWorkDir(String path) {
    Directory(path).delete(recursive: true).ignore();
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
  /// On macOS and Windows this never returns: the helper is already waiting on
  /// our PID, and staying alive would only make it wait longer. On Android the
  /// system installer takes over the screen on its own — the app is not
  /// quit, because cancelling that screen must leave a working app behind, not
  /// a process that already exited.
  static Future<void> applyAndRestart(PreparedUpdate update) async {
    if (update._isAndroidApk) {
      await AndroidApkInstaller.install(update._launcherPath);
      return;
    }

    if (Platform.isWindows) {
      await Process.start(
        'cmd',
        ['/c', 'start', '', '/min', update._launcherPath],
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

/// Nothing to unpack: the artifact *is* the installer. It runs silently after
/// we quit, then the helper starts the freshly installed executable — the Inno
/// script marks its own post-install launch `skipifsilent`, so the relaunch is
/// ours to do.
Future<PreparedUpdate> _prepareWindows(
    String setupPath, String workDir) async {
  final target = Platform.resolvedExecutable;

  // Lives next to workDir, not inside it: the cleanup step it runs deletes
  // workDir, and a script cannot survive deleting its own containing folder —
  // see the comment on _windowsCleanup below.
  final cleanup = File(
      '${Directory.systemTemp.path}\\onyx-update-cleanup-$pid.cmd');
  await cleanup.writeAsString(_windowsCleanup(workDir: workDir));

  final script = File('$workDir\\apply-update.cmd');
  await script.writeAsString(_windowsLauncher(
    pid: pid,
    setup: setupPath,
    target: target,
    cleanupScript: cleanup.path,
  ));
  return PreparedUpdate._(script.path, workDir);
}

/// `/SILENT` still shows a progress window (and the UAC prompt the installer
/// requires), which is the honest thing to show while system files change.
String _windowsLauncher({
  required int pid,
  required String setup,
  required String target,
  required String cleanupScript,
}) {
  final s = _windowsQuote(setup);
  final t = _windowsQuote(target);
  final c = _windowsQuote(cleanupScript);
  return '''
@echo off
rem Genere par Onyx - applique la mise a jour des que l'app est fermee.
setlocal
set /a tries=0
:wait
tasklist /FI "PID eq $pid" 2>nul | find "$pid" >nul || goto run
set /a tries+=1
if %tries% gtr 150 exit /b 1
ping -n 2 127.0.0.1 >nul
goto wait

:run
start "" /wait $s /SILENT /NOCANCEL /NORESTART /SUPPRESSMSGBOXES
start "" $t
start "" /min $c
''';
}

/// Deletes the temp directory this update was staged in — but from outside
/// it, and after a short delay.
///
/// This used to be the last line of [_windowsLauncher] itself
/// (`rmdir /s /q` on its own containing folder). cmd.exe reads a batch file
/// from disk one line at a time rather than loading it upfront, so deleting
/// the folder out from under a script that is still executing *from a file in
/// that folder* made it lose track of where it was: it failed with "Le chemin
/// d'accès spécifié est introuvable" instead of exiting, leaving a console
/// window behind — one the freshly relaunched app then appeared to depend on,
/// since closing it took Onyx down too. This script never reads itself from
/// workDir, so deleting workDir out from under it is safe; the delay just
/// gives the launcher's own console time to close first.
///
/// Left behind afterward rather than self-deleted: a few hundred leftover
/// bytes in the system temp directory is a better trade than reintroducing
/// the very same class of bug to shave them off.
String _windowsCleanup({required String workDir}) {
  final w = _windowsQuote(workDir);
  return '''
@echo off
ping -n 3 127.0.0.1 >nul
rmdir /s /q $w
''';
}

// -----------------------------------------------------------------------------
// Quoting
// -----------------------------------------------------------------------------

/// Both launchers are generated text, so a path carrying the shell's own quote
/// character would break out of the string. Temp dirs and install paths never
/// contain one; refusing is the safe answer if it ever happens.
String _shellQuote(String path) {
  if (path.contains("'") || path.contains('\n')) {
    throw UpdateException('Chemin non supporté pour la mise à jour : $path');
  }
  return "'$path'";
}

String _windowsQuote(String path) {
  if (path.contains('"') || path.contains('\n')) {
    throw UpdateException('Chemin non supporté pour la mise à jour : $path');
  }
  return '"$path"';
}
