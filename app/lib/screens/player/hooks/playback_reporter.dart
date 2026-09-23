import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../models/server_activity.dart';
import '../../../services/api_client.dart';
import '../../../services/client_log.dart';
import '../../../services/download_manager.dart';
import '../../../services/playback_access.dart';
import '../playback/playback_stats.dart';

/// L'instant de la lecture, tel que le rapporteur le décrit au serveur.
typedef PlaybackMoment = ({
  int positionSeconds,
  int durationSeconds,
  bool playing,
  PlayMethod method,
  String quality,
});

/// Ce que le lecteur dit au serveur pendant qu'il lit : la séance (activité et
/// historique), le battement de progression, et le journal de la séance.
///
/// Sorti du contrôleur du lecteur, qui le portait au milieu des sessions HLS
/// et des pistes. Il ne connaît du lecteur que [moment], relu à chaque envoi :
/// un rapport décrit l'instant où il part, pas celui où il a été programmé.
class PlaybackReporter {
  PlaybackReporter({required this.moment, required this.stats});

  final PlaybackMoment Function() moment;

  /// Les mesures de la séance, envoyées avec son journal.
  final PlaybackStatsCollector stats;

  Timer? _heartbeat;

  /// Le signal d'arrêt part une seule fois, quel que soit le chemin qui y
  /// mène en premier : fin, abandon ou fermeture de l'écran.
  bool _stopped = false;

  /// Le rang de la première ligne de journal de cette lecture.
  ///
  /// Ce qui délimite « les logs de cette séance » dans le tampon commun de
  /// [ClientLog] : la tranche part de là et va jusqu'à l'arrêt. Voir
  /// [ClientLog.since].
  int _logMark = 0;

  /// Marque le début du journal de cette séance.
  void markLogStart() => _logMark = ClientLog.sequence;

  /// Ouvre la séance côté serveur, dès l'ouverture du média.
  ///
  /// Pas à la première image : une lecture qui échoue au démarrage n'aurait
  /// alors pas de séance à qui rattacher son journal — et ce sont précisément
  /// ces journaux-là qu'on vient chercher.
  void open({required int mediaId, required ApiClient apiClient}) {
    _stopped = false;
    _report(mediaId: mediaId, apiClient: apiClient, event: 'start');
  }

  void startHeartbeat({required int mediaId, required ApiClient apiClient}) {
    _heartbeat?.cancel();
    _stopped = false;
    // La séance est déjà ouverte depuis `open()` ; ce second signal ne la
    // duplique pas — le serveur reconnaît la même clé et le même média — il
    // rafraîchit la méthode de lecture, qui n'était pas encore résolue là-bas.
    _report(mediaId: mediaId, apiClient: apiClient, event: 'start');
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      // The activity signal goes out paused too: a film on pause is still
      // someone watching, and the dashboard says so.
      _report(mediaId: mediaId, apiClient: apiClient);
      if (moment().playing) {
        _sendProgress(
            mediaId: mediaId, apiClient: apiClient, isFinished: false);
      }
    });
  }

  void cancelHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// Annonce que la lecture reprend ici : le serveur met en pause, chez les
  /// autres appareils du compte, ce même titre (voir `playback_handoff.go`).
  void announceHere({required int mediaId, required ApiClient apiClient}) {
    _report(mediaId: mediaId, apiClient: apiClient, event: 'start');
  }

  /// Ferme la séance, son journal avec elle.
  void stop({required int mediaId, required ApiClient apiClient}) {
    _report(mediaId: mediaId, apiClient: apiClient, event: 'stop');
  }

  /// Fait monter le journal sans attendre l'arrêt de la séance.
  ///
  /// Une séance qui ne bat plus est balayée côté serveur au bout d'une minute,
  /// et sa ligne d'historique disparaît avec elle si aucun journal d'erreur n'y
  /// est attaché. Or un démarrage abandonné n'a pas de battement — il n'a
  /// jamais commencé — et quelqu'un qui lit le message d'erreur avant de fermer
  /// l'écran met volontiers plus d'une minute. Attendre la fermeture perdait
  /// donc précisément les journaux pour lesquels tout ceci existe.
  void flushLogs(ApiClient? apiClient) {
    if (apiClient == null || _stopped) return;
    unawaited(_uploadSession(apiClient, last: false));
  }

  /// Arrête le battement, ferme la séance et envoie la dernière position.
  Future<void> finish({
    required int mediaId,
    required ApiClient apiClient,
    bool isFinished = false,
  }) async {
    cancelHeartbeat();
    _report(mediaId: mediaId, apiClient: apiClient, event: 'stop');

    final now = moment();
    if (now.positionSeconds > 0) {
      var finalIsFinished = isFinished;
      if (!finalIsFinished &&
          now.durationSeconds > 0 &&
          (now.positionSeconds / now.durationSeconds) * 100 >= 90.0) {
        finalIsFinished = true;
      }
      await _sendProgress(
          mediaId: mediaId, apiClient: apiClient, isFinished: finalIsFinished);
    }
  }

  /// Tells the server what this player is doing, for its dashboard and
  /// history. Best effort: an older server has no such route, and playback
  /// never waits on it.
  void _report({
    required int mediaId,
    required ApiClient apiClient,
    String event = 'progress',
  }) {
    if (_stopped) return;
    if (event == 'stop') _stopped = true;
    // Figé maintenant : ce qui suit peut partir après un aller-retour réseau,
    // et le rapport doit décrire l'instant de l'arrêt, pas celui de l'envoi.
    final now = moment();
    Future<void> send() => apiClient
        .reportPlayback(
          mediaId: mediaId,
          positionSeconds: now.positionSeconds,
          durationSeconds: now.durationSeconds,
          paused: !now.playing,
          playMethod: now.method,
          quality: now.quality,
          event: event,
        )
        .catchError((_) {});

    // Le journal part avec le dernier signal, et **avant** lui : le serveur le
    // rattache à la séance encore ouverte, et c'est ce signal-là qui la ferme.
    // L'ordre inverse écrirait dans le vide une fois sur deux.
    if (event == 'stop') {
      unawaited(_uploadSession(apiClient, last: true).whenComplete(send));
      return;
    }
    unawaited(send());
  }

  /// Envoie au serveur ce que cette séance a écrit et ce qu'elle a mesuré.
  ///
  /// Le serveur réécrit la ligne à chaque envoi plutôt que d'en empiler
  /// (`ON CONFLICT DO UPDATE`, voir `playback_logs.go`) : envoyer deux fois ne
  /// duplique rien, le second envoi remplace simplement le premier, plus
  /// complet puisque plus tardif.
  ///
  /// [last] déclenche un dernier relevé avant le résumé. Ce qui s'est passé
  /// depuis le dernier échantillon compte autant que le reste — c'est souvent
  /// là que la lecture s'est dégradée.
  Future<void> _uploadSession(ApiClient apiClient, {required bool last}) async {
    final summary = last ? await stats.finish() : stats.summary;
    final lines = ClientLog.since(_logMark);
    if (lines.isEmpty && summary.isEmpty) return;
    try {
      await apiClient.uploadPlaybackLogs(
        lines,
        stats: summary.isEmpty ? null : summary.toJson(),
      );
    } catch (_) {
      // Un serveur plus ancien n'a pas cette route, et une lecture ne dépend
      // pas de son journal.
    }
  }

  Future<void> _sendProgress({
    required int mediaId,
    required ApiClient apiClient,
    required bool isFinished,
  }) async {
    final now = moment();
    final posSeconds = now.positionSeconds;
    final durSeconds = now.durationSeconds;
    if (posSeconds <= 0) return;

    // Le serveur d'abord, le disque ensuite — et le disque dans tous les cas.
    //
    // C'est ce qui rend le hors ligne transparent : un épisode téléchargé garde
    // son avancement dans le manifeste, marqué à resynchroniser tant que le
    // serveur ne l'a pas accepté. Au retour de la connexion, le rejeu le porte
    // et l'épisode apparaît vu partout ailleurs, sans que le lecteur ait eu à
    // savoir s'il y avait du réseau.
    var synced = false;
    var resolvedFinished = isFinished;
    try {
      resolvedFinished = await apiClient.sendProgress(
        mediaId: mediaId,
        currentPositionSeconds: posSeconds,
        duration: durSeconds,
        isFinished: isFinished,
        clientUpdatedAt: DateTime.now().toUtc(),
      );
      synced = true;
    } catch (e) {
      debugPrint(
          "Player: failed to sync progress: ${redactPlaybackDiagnostic(e)}");
    }

    // The old server may answer after a relay changed the download catalog.
    if (apiClient.servers.active?.id != apiClient.accountId) return;
    await DownloadManager.instance.recordProgress(
      mediaId: mediaId,
      positionSeconds: posSeconds,
      durationSeconds: durSeconds,
      isFinished: resolvedFinished,
      syncedWithServer: synced,
    );
  }
}
