import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_download.dart';
import '../../services/api_client.dart';
import '../../services/app_updater.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_platform.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';

/// Walks the user through an in-place update: download, unpack, restart.
///
/// With [autoStart], the whole thing runs on its own — the app was found out
/// of date against the server, so the download starts immediately and the
/// restart follows a short countdown once it is ready, instead of waiting on
/// a click at every step. The countdown can still be called off: postponing
/// keeps the running version.
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppDownload download,
  bool autoStart = false,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AppUpdateDialog(download: download, autoStart: autoStart),
  );
}

enum _Step { idle, downloading, installing, ready, failed }

class _AppUpdateDialog extends StatefulWidget {
  final AppDownload download;
  final bool autoStart;

  const _AppUpdateDialog({required this.download, this.autoStart = false});

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  _Step _step = _Step.idle;
  double? _progress;
  String? _error;
  PreparedUpdate? _prepared;
  CancelToken? _cancel;
  String? _workDir;

  /// Seconds left before an auto-detected update restarts on its own once
  /// ready, or null when no countdown is running (a manually opened dialog
  /// still waits on "Redémarrer maintenant").
  int? _autoRestartIn;
  Timer? _autoRestartTimer;
  static const _autoRestartDelay = 10;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    // Closing mid-download stops it; a half-written installer is worthless, so
    // the whole scratch directory goes with it.
    _cancel?.cancel();
    _autoRestartTimer?.cancel();
    if (_prepared == null) _discardWorkDir();
    super.dispose();
  }

  void _discardWorkDir() {
    final dir = _workDir;
    _workDir = null;
    if (dir != null) AppUpdater.discardWorkDir(dir);
  }

  Future<void> _start() async {
    final api = context.read<ApiClient>();
    setState(() {
      _step = _Step.downloading;
      _progress = null;
      _error = null;
    });

    try {
      _discardWorkDir();
      final workDir = await AppUpdater.createWorkDir();
      _workDir = workDir;
      final archive = '$workDir/${widget.download.file}';
      final cancel = CancelToken();
      _cancel = cancel;

      await api.downloadAppArtifact(
        widget.download,
        archive,
        cancelToken: cancel,
        onReceiveProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress = received / total);
        },
      );
      _cancel = null;
      if (!mounted) return;

      setState(() {
        _step = _Step.installing;
        _progress = null;
      });
      final prepared = await AppUpdater.prepare(
        archivePath: archive,
        workDir: workDir,
      );
      if (!mounted) {
        await prepared.discard();
        return;
      }
      setState(() {
        _prepared = prepared;
        _step = _Step.ready;
      });
      if (widget.autoStart) _startAutoRestartCountdown();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      _fail(tr('Téléchargement interrompu. Vérifiez la connexion au serveur.'));
    } on UpdateException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail(tr('La mise à jour a échoué.'));
    }
  }

  void _fail(String message) {
    _discardWorkDir();
    if (!mounted) return;
    setState(() {
      _step = _Step.failed;
      _error = message;
    });
  }

  Future<void> _restart() async {
    final prepared = _prepared;
    if (prepared == null) return;
    _autoRestartTimer?.cancel();
    try {
      await AppUpdater.applyAndRestart(prepared);
    } on UpdateException catch (e) {
      // L'installeur Android n'a pas pu s'ouvrir : sa raison est lisible.
      _prepared = null;
      _fail(e.message);
      return;
    } catch (_) {
      // The helper never started (Windows updater missing or blocked): the
      // app is still running, so say so instead of hanging on this dialog.
      _prepared = null;
      _fail(tr('Impossible de lancer la mise à jour.'));
      return;
    }
    // Desktop never reaches here — the helper it just launched is waiting on
    // this process to exit. Android does: its installer takes over the
    // screen on its own, so the dialog underneath is just clutter once that
    // handoff has happened.
    if (mounted) Navigator.of(context).pop();
  }

  /// Counts down to an unattended restart once an auto-detected update is
  /// ready. Cancelling the dialog (`_close`) or the countdown's own button
  /// stops it — the app never restarts without this having run to zero.
  void _startAutoRestartCountdown() {
    setState(() => _autoRestartIn = _autoRestartDelay);
    _autoRestartTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final remaining = (_autoRestartIn ?? 1) - 1;
      if (remaining <= 0) {
        timer.cancel();
        _restart();
        return;
      }
      setState(() => _autoRestartIn = remaining);
    });
  }

  void _cancelAutoRestart() {
    _autoRestartTimer?.cancel();
    setState(() => _autoRestartIn = null);
  }

  /// Leaving with an update already unpacked would strand a few hundred MB in
  /// the temp directory, so drop it — it is re-downloaded next time.
  Future<void> _close() async {
    final prepared = _prepared;
    _autoRestartTimer?.cancel();
    Navigator.of(context).pop();
    await prepared?.discard();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(_title()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _message(),
            style: const TextStyle(color: AppColors.textMuted, fontSize: AppType.subhead),
          ),
          if (_step == _Step.downloading || _step == _Step.installing) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _step == _Step.downloading ? _progress : null,
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
              ),
            ),
          ],
        ],
      ),
      actions: _actions(),
    );
  }

  String _title() {
    switch (_step) {
      case _Step.downloading:
        return tr('Téléchargement…');
      case _Step.installing:
        return tr('Installation…');
      case _Step.ready:
        return tr('Mise à jour prête');
      case _Step.failed:
        return tr('Mise à jour impossible');
      case _Step.idle:
        return tr('Mise à jour disponible');
    }
  }

  String _message() {
    final version = widget.download.version;
    switch (_step) {
      case _Step.downloading:
        final percent = _progress == null
            ? ''
            : ' — ${(_progress! * 100).toStringAsFixed(0)} %';
        return tr('Récupération de la version {0}{1}', [version, percent]);
      case _Step.installing:
        return tr('Préparation des fichiers. Onyx reste utilisable.');
      case _Step.ready:
        final countdown = _autoRestartIn;
        final base = AppPlatform.isAndroid
            ? tr('Prêt à installer la version {0}. Android va demander une '
                'confirmation.', [version])
            : tr('Onyx va se fermer, s’installer en version {0}, puis se rouvrir.', [version]);
        if (countdown == null) return base;
        return tr('{0} Ouverture automatique dans {1}s…', [base, countdown]);
      case _Step.failed:
        return _error ?? tr('La mise à jour a échoué.');
      case _Step.idle:
        final size = widget.download.formattedSize;
        final action = AppPlatform.isAndroid
            ? tr('Onyx la télécharge, puis Android demandera de confirmer '
                'l’installation.')
            : tr('Onyx la télécharge, l’installe et redémarre tout seul.');
        return tr('La version {0} est disponible{1}. {2}', [version, size.isEmpty ? '' : ' ($size)', action]);
    }
  }

  List<Widget> _actions() {
    switch (_step) {
      case _Step.idle:
        return [
          TextButton(onPressed: _close, child: Text(tr('Plus tard'))),
          FilledButton(onPressed: _start, child: Text(tr('Mettre à jour'))),
        ];
      case _Step.downloading:
      case _Step.installing:
        return [
          TextButton(onPressed: _close, child: Text(tr('Annuler'))),
        ];
      case _Step.ready:
        return [
          TextButton(
            onPressed: _autoRestartIn != null ? _cancelAutoRestart : _close,
            child: Text(_autoRestartIn != null ? tr('Annuler') : tr('Plus tard')),
          ),
          FilledButton(
            onPressed: _restart,
            child: Text(AppPlatform.isAndroid
                ? tr('Installer maintenant')
                : tr('Redémarrer maintenant')),
          ),
        ];
      case _Step.failed:
        return [
          TextButton(onPressed: _close, child: Text(tr('Fermer'))),
          FilledButton(onPressed: _start, child: Text(tr('Réessayer'))),
        ];
    }
  }
}
