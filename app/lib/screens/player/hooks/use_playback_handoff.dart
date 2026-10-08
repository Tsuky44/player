import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../models/remote_playback.dart';
import '../../../services/api_client.dart';
import '../../../tv/tv_mode.dart';
import '../playback/away_from_screen.dart';
import 'use_player_controller.dart';

/// Reprise sur un autre appareil : le serveur est interrogé toutes les
/// quelques secondes pour savoir si ce titre a démarré ailleurs sur le même
/// compte. [handedOffTo] nomme cet appareil tant que la lecture y est.
///
/// Porte aussi la TV éteinte puis rallumée sur le lecteur ([PlayerAwayGuard]) :
/// les deux répondent à la même question, « où en est la lecture, si ce n'est
/// pas ici ».
class PlaybackHandoffWatch extends ChangeNotifier {
  PlaybackHandoffWatch({
    required this.api,
    required this.controller,
    required this.inParty,
    required this.isLeaving,
    required this.pause,
    required this.resume,
    required this.leave,
  });

  final ApiClient? Function() api;
  final PlayerController controller;

  /// Une séance « Regarder ensemble » a ses propres règles : plusieurs
  /// appareils y lisent le même titre, c'est le but.
  final bool Function() inParty;

  /// Le lecteur s'en va, ou n'est plus monté.
  final bool Function() isLeaving;

  /// Met la lecture en pause, voulue comme telle.
  final VoidCallback pause;

  /// Relance la lecture, voulue comme telle.
  final VoidCallback resume;
  final VoidCallback leave;

  static const Duration _pollInterval = Duration(seconds: 4);

  Timer? _timer;
  String? handedOffTo;
  bool resumingHere = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
    _awayGuard.attach();
  }

  /// La TV éteinte puis rallumée sur le lecteur. Voir [PlayerAwayGuard].
  late final PlayerAwayGuard _awayGuard = PlayerAwayGuard(
    // Une séance « Regarder ensemble » garde ses propres règles.
    enabled: () =>
        TvMode.isTv && !inParty() && !isLeaving() && api() != null,
    pause: pause,
    closeSession: () async {
      final client = api();
      final mediaId = controller.mediaId;
      if (client == null || mediaId == null) return;
      await controller.reporter.suspend(mediaId: mediaId, apiClient: client);
    },
    reopenSession: () {
      final client = api();
      final mediaId = controller.mediaId;
      if (client == null || mediaId == null || isLeaving()) return;
      controller.reporter
          .startHeartbeat(mediaId: mediaId, apiClient: client, announce: false);
    },
    localSeconds: () => controller.position.inSeconds,
    fetchProgress: () async {
      final client = api();
      final mediaId = controller.mediaId;
      if (client == null || mediaId == null) return null;
      return parseServerProgress(await client.getProgress(mediaId));
    },
    apply: (verdict) {
      if (isLeaving()) return;
      switch (verdict) {
        case StayHere():
          break;
        case SeekTo(:final seconds):
          unawaited(controller.seekToAbsoluteSeconds(seconds));
        case LeavePlayer():
          leave();
      }
    },
  );

  Future<void> _poll() async {
    final client = api();
    if (client == null || inParty() || handedOffTo != null || isLeaving()) {
      return;
    }
    final PlaybackHandoff? handoff;
    try {
      handoff = await client.getPlaybackHandoff();
    } catch (_) {
      return; // Serveur plus ancien, ou réseau absent : on lit, simplement.
    }
    if (handoff == null || isLeaving() || handedOffTo != null) return;
    pause();
    // Sa position d'ici est désormais en retard : quitter le lecteur ne doit
    // pas l'écrire par-dessus celle de l'appareil qui lit.
    controller.reporter.yieldProgress();
    handedOffTo = handoff.deviceName;
    _notify();
  }

  /// Rapatrie ici la lecture qui continue sur l'autre appareil, là où il en
  /// est.
  Future<void> resumeHere() async {
    final client = api();
    if (client == null || resumingHere) return;
    resumingHere = true;
    _notify();
    AwayVerdict verdict = const StayHere();
    try {
      final handoff =
          await client.getPlaybackHandoff().catchError((_) => null);
      final remote = handoff?.playback;
      // L'autre appareil s'est arrêté, ou lit autre chose : sa dernière
      // position de ce média est sur le serveur, pas ici.
      verdict = remote != null && remote.mediaId == controller.mediaId
          ? SeekTo(remote.positionSeconds)
          : await _awayGuard.reconcile();
      if (verdict case SeekTo(:final seconds)) {
        await controller.seekToAbsoluteSeconds(seconds);
      }
    } finally {
      if (verdict is LeavePlayer) {
        resumingHere = false;
        _notify();
        if (!isLeaving()) leave();
      } else {
        controller.announcePlaybackHere();
        resume();
        handedOffTo = null;
        resumingHere = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _awayGuard.dispose();
    super.dispose();
  }
}
