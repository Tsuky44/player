import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../utils/on_screen.dart';

/// Ce que le serveur retient de l'avancement d'un média.
typedef ServerProgress = ({int positionSeconds, bool finished});

/// Lit la réponse de `GET /api/progress`.
ServerProgress parseServerProgress(Map<String, dynamic> json) => (
      positionSeconds: (json['current_position_seconds'] as num?)?.toInt() ?? 0,
      finished: json['is_finished'] as bool? ?? false,
    );

/// Ce que le lecteur fait d'une position qui a pu avancer sur un autre
/// appareil pendant qu'il n'était pas regardé.
sealed class AwayVerdict {
  const AwayVerdict();
}

/// Rien n'a bougé ailleurs : le lecteur reste là où il était.
final class StayHere extends AwayVerdict {
  const StayHere();
}

/// Un autre appareil a continué ce média : le lecteur se cale sur lui.
final class SeekTo extends AwayVerdict {
  const SeekTo(this.seconds);
  final int seconds;
}

/// Un autre appareil a fini ce média : il n'y a plus rien à reprendre ici.
final class LeavePlayer extends AwayVerdict {
  const LeavePlayer();
}

/// L'écart en deçà duquel la position du serveur est la nôtre : celle qu'on a
/// envoyée en partant, arrondie à la seconde, ou le battement qui la
/// précédait de quelques secondes.
const int awayPositionTolerance = 10;

/// Confronte la position locale à celle du serveur. Le serveur a le dernier
/// mot : c'est lui qui a entendu le téléphone pendant que la TV dormait.
///
/// Sans réponse du serveur, on ne sait rien de plus — le lecteur reste où il
/// est plutôt que de se tromper.
AwayVerdict reconcileWithServer({
  required int localSeconds,
  required ServerProgress? server,
}) {
  if (server == null) return const StayHere();
  if (server.finished) return const LeavePlayer();
  if ((server.positionSeconds - localSeconds).abs() <= awayPositionTolerance) {
    return const StayHere();
  }
  return SeekTo(server.positionSeconds);
}

/// Met le lecteur de côté quand l'app quitte l'écran, et le recale sur le
/// serveur quand elle y revient.
///
/// La panne d'origine : sur Fire TV, éteindre la télé laisse l'app ouverte
/// sur le lecteur. Elle continuait de lire dans le vide et de battre — le
/// téléphone proposait alors de « reprendre » là où en était la TV — puis, au
/// rallumage, repartait de sa propre position alors qu'un épisode avait été
/// regardé entre-temps sur le téléphone, et la réécrivait sur le serveur en
/// quittant.
///
/// En partant, le lecteur se met en pause et ferme sa séance avec sa dernière
/// position ; il cède alors la progression (voir
/// `PlaybackReporter.yieldProgress`). En revenant, il demande au serveur où en
/// est ce média et suit [reconcileWithServer].
class PlayerAwayGuard {
  PlayerAwayGuard({
    required this.enabled,
    required this.pause,
    required this.closeSession,
    required this.reopenSession,
    required this.localSeconds,
    required this.fetchProgress,
    required this.apply,
  });

  /// Le garde agit-il en ce moment ? Sur TV seulement : sur un téléphone,
  /// quitter l'app peut vouloir dire l'image dans l'image ou l'écoute écran
  /// verrouillé, et rien ne s'y lit « dans le vide ».
  final bool Function() enabled;
  final void Function() pause;

  /// Envoie la dernière position et ferme la séance côté serveur.
  final Future<void> Function() closeSession;

  /// Rouvre la séance, sans reprendre la main aux autres appareils.
  final void Function() reopenSession;
  final int Function() localSeconds;
  final Future<ServerProgress?> Function() fetchProgress;
  final void Function(AwayVerdict verdict) apply;

  bool _away = false;
  bool _attached = false;

  @visibleForTesting
  bool get isAway => _away;

  void attach() {
    if (_attached) return;
    _attached = true;
    AppForeground.visible.addListener(_changed);
  }

  void dispose() {
    if (!_attached) return;
    _attached = false;
    AppForeground.visible.removeListener(_changed);
  }

  void _changed() {
    if (AppForeground.isVisible) {
      if (!_away) return;
      _away = false;
      unawaited(_comeBack());
      return;
    }
    // Tout de suite, sans délai de grâce : une Fire TV qui s'endort gèle
    // l'app avant qu'une minuterie de quelques secondes ne tombe.
    if (_away || !enabled()) return;
    _away = true;
    pause();
    unawaited(closeSession());
  }

  Future<void> _comeBack() async {
    reopenSession();
    apply(await reconcile());
  }

  /// Ce que le serveur dit de la position locale. Sert aussi à « Reprendre
  /// ici » quand l'appareil qui avait pris la main s'est arrêté.
  Future<AwayVerdict> reconcile() async {
    ServerProgress? server;
    try {
      server = await fetchProgress();
    } catch (_) {
      server = null; // Réseau absent au réveil : on reste où l'on était.
    }
    return reconcileWithServer(localSeconds: localSeconds(), server: server);
  }
}
