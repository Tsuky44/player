import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:onyx_background_downloads/onyx_background_downloads.dart';

import '../../models/offline_download.dart';
import '../../utils/format.dart';
import '../download_manager.dart';

/// Ce que dit la notification du service de téléchargement Android.
@immutable
class DownloadNotice {
  const DownloadNotice({
    required this.title,
    required this.text,
    required this.percent,
  });

  final String title;
  final String text;

  /// -1 tant que la taille totale est inconnue : une barre indéterminée dit la
  /// vérité, une barre à zéro non.
  final int percent;

  @override
  bool operator ==(Object other) =>
      other is DownloadNotice &&
      other.title == title &&
      other.text == text &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(title, text, percent);

  @override
  String toString() => 'DownloadNotice($title · $text · $percent)';
}

/// La notification à montrer, ou null quand il n'y a plus rien à garder
/// éveillé.
///
/// [transferring] vaut vrai tant que la file tourne, **entre deux médias
/// compris** : c'est ce qui garde le service d'un épisode au suivant. Android
/// refuse de redémarrer un service de premier plan depuis l'arrière-plan —
/// l'arrêter entre deux épisodes, écran éteint, arrêterait la saison.
/// Une file à l'arrêt (réseau refusé, serveur perdu) ne garde rien éveillé :
/// elle attend un événement, pas un processeur.
DownloadNotice? downloadNoticeFor(
  Iterable<OfflineDownload> downloads, {
  required bool transferring,
}) {
  if (!transferring) return null;
  OfflineDownload? active;
  var waiting = 0;
  for (final entry in downloads) {
    if (entry.status == DownloadStatus.downloading) {
      active ??= entry;
    } else if (entry.status == DownloadStatus.queued) {
      waiting++;
    }
  }
  if (active == null && waiting == 0) return null;
  final queued = waiting > 0 ? '$waiting en attente' : null;
  if (active == null) {
    return DownloadNotice(title: 'Téléchargements', text: queued!, percent: -1);
  }

  final total = active.bytesTotal;
  final percent =
      total > 0 ? (active.bytesReceived * 100 ~/ total).clamp(0, 100) : -1;
  final code = active.episodeCode;
  final title = code == null
      ? active.groupTitle
      : '${active.groupTitle} · $code';
  return DownloadNotice(
    title: title,
    text: [
      if (total > 0)
        '${formatBytes(active.bytesReceived)} sur ${formatBytes(total)}'
      else
        'Téléchargement…',
      if (queued != null) queued,
    ].join(' · '),
    percent: percent,
  );
}

/// Tient le service de téléchargement Android au rythme du magasin hors ligne
/// (ADR-0040).
///
/// Écran éteint, Android gèle une app sans service de premier plan, puis la
/// sort du réseau : le transfert, qui est du Dart, s'arrêtait avec. Le service
/// garde le processus vivant, et sa notification dit où en est la file.
class DownloadKeepAlive {
  DownloadKeepAlive(
    this._manager, {
    DownloadForegroundService service = const DownloadForegroundService(),
  }) : _service = service;

  final DownloadManager _manager;
  final DownloadForegroundService _service;

  DownloadNotice? _shown;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailing;

  /// Android écarte les mises à jour d'une notification qui en reçoit plus de
  /// quelques-unes par seconde ; le pourcentage n'en demande pas tant.
  static const Duration minGap = Duration(seconds: 1);

  void start() {
    _manager.addListener(_sync);
    _sync();
  }

  void _sync() {
    final notice = downloadNoticeFor(
      _manager.downloads,
      transferring: _manager.isTransferring,
    );
    if (notice == _shown) return;
    // Seule une mise à jour se diffère : démarrer et arrêter le service
    // partent tout de suite.
    final wait = minGap - DateTime.now().difference(_lastSent);
    if (notice != null && _shown != null && wait > Duration.zero) {
      _trailing ??= Timer(wait, () {
        _trailing = null;
        _sync();
      });
      return;
    }
    _trailing?.cancel();
    _trailing = null;
    _shown = notice;
    _lastSent = DateTime.now();
    unawaited(_send(notice));
  }

  Future<void> _send(DownloadNotice? notice) async {
    try {
      if (notice == null) {
        await _service.stop();
      } else {
        await _service.show(
          title: notice.title,
          text: notice.text,
          percent: notice.percent,
        );
      }
    } catch (e) {
      debugPrint('Downloads: service de premier plan indisponible: $e');
    }
  }
}
