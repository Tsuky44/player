import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_download.dart';
import '../../services/api_client.dart';
import '../../services/app_updater.dart';
import '../../theme/app_colors.dart';

/// Walks the user through an in-place update: download, unpack, restart.
///
/// Nothing is installed behind their back — the swap only happens once they
/// press "Redémarrer maintenant", and postponing keeps the running version.
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppDownload download,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AppUpdateDialog(download: download),
  );
}

enum _Step { idle, downloading, installing, ready, failed }

class _AppUpdateDialog extends StatefulWidget {
  final AppDownload download;

  const _AppUpdateDialog({required this.download});

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

  @override
  void dispose() {
    // Closing mid-download stops it; a half-written installer is worthless, so
    // the whole scratch directory goes with it.
    _cancel?.cancel();
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
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      _fail('Téléchargement interrompu. Vérifiez la connexion au serveur.');
    } on UpdateException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('La mise à jour a échoué.');
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
    await AppUpdater.applyAndRestart(prepared);
  }

  /// Leaving with an update already unpacked would strand a few hundred MB in
  /// the temp directory, so drop it — it is re-downloaded next time.
  Future<void> _close() async {
    final prepared = _prepared;
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
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
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
        return 'Téléchargement…';
      case _Step.installing:
        return 'Installation…';
      case _Step.ready:
        return 'Mise à jour prête';
      case _Step.failed:
        return 'Mise à jour impossible';
      case _Step.idle:
        return 'Mise à jour disponible';
    }
  }

  String _message() {
    final version = widget.download.version;
    switch (_step) {
      case _Step.downloading:
        final percent = _progress == null
            ? ''
            : ' — ${(_progress! * 100).toStringAsFixed(0)} %';
        return 'Récupération de la version $version$percent';
      case _Step.installing:
        return 'Préparation des fichiers. Onyx reste utilisable.';
      case _Step.ready:
        return 'Onyx va se fermer, s’installer en version $version, '
            'puis se rouvrir.';
      case _Step.failed:
        return _error ?? 'La mise à jour a échoué.';
      case _Step.idle:
        final size = widget.download.formattedSize;
        return 'La version $version est disponible'
            '${size.isEmpty ? '' : ' ($size)'}. '
            'Onyx la télécharge, l’installe et redémarre tout seul.';
    }
  }

  List<Widget> _actions() {
    switch (_step) {
      case _Step.idle:
        return [
          TextButton(onPressed: _close, child: const Text('Plus tard')),
          FilledButton(onPressed: _start, child: const Text('Mettre à jour')),
        ];
      case _Step.downloading:
      case _Step.installing:
        return [
          TextButton(onPressed: _close, child: const Text('Annuler')),
        ];
      case _Step.ready:
        return [
          TextButton(onPressed: _close, child: const Text('Plus tard')),
          FilledButton(
            onPressed: _restart,
            child: const Text('Redémarrer maintenant'),
          ),
        ];
      case _Step.failed:
        return [
          TextButton(onPressed: _close, child: const Text('Fermer')),
          FilledButton(onPressed: _start, child: const Text('Réessayer')),
        ];
    }
  }
}
