import 'dart:async';

import 'package:flutter/foundation.dart';

/// La minuterie de veille : « dans 30 minutes, coupe ».
///
/// Elle vit hors du lecteur, parce qu'un lecteur ne dure qu'un épisode :
/// passer au suivant remplace l'écran, et une minuterie rangée dedans
/// repartirait de zéro — ou disparaîtrait — à chaque générique. Réglée sur
/// 30 minutes devant un épisode de 20, elle coupe donc 10 minutes dans le
/// suivant.
///
/// Elle compte le temps de l'horloge, pas celui du film : c'est une heure de
/// coucher, et une pause au milieu ne la repousse pas.
///
/// Elle ne coupe rien elle-même. À l'échéance elle devient [isDue] et le
/// lecteur à l'écran la prend avec [takeDue] ; si l'échéance tombe entre deux
/// épisodes, quand aucun lecteur n'est prêt, c'est le suivant qui la prend en
/// démarrant.
class SleepTimer extends ChangeNotifier {
  SleepTimer._();

  static final SleepTimer instance = SleepTimer._();

  /// Les durées proposées dans le menu du lecteur.
  static const List<Duration> choices = [
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(hours: 1),
    Duration(hours: 2),
  ];

  Timer? _timer;
  Duration? _chosen;
  DateTime? _endsAt;
  bool _due = false;
  int _players = 0;

  /// La durée choisie tant que la minuterie court, null sinon.
  Duration? get chosen => _chosen;

  bool get isActive => _chosen != null;

  /// Ce qu'il reste avant la coupure, null quand rien ne court.
  Duration? get remaining {
    final endsAt = _endsAt;
    if (endsAt == null) return null;
    final left = endsAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// L'échéance est tombée et aucun lecteur ne l'a encore prise.
  bool get isDue => _due;

  /// Lance la minuterie, ou la relance si elle courait déjà.
  void start(Duration duration) {
    _timer?.cancel();
    _chosen = duration;
    _endsAt = DateTime.now().add(duration);
    _due = false;
    _timer = Timer(duration, _expire);
    notifyListeners();
  }

  void cancel() {
    if (!isActive && !_due) return;
    _clear();
    notifyListeners();
  }

  /// Prend l'échéance : vrai une seule fois, pour le lecteur qui met en pause.
  bool takeDue() {
    if (!_due) return false;
    _due = false;
    return true;
  }

  /// Un lecteur s'ouvre. Voir [release].
  void retain() => _players++;

  /// Un lecteur se ferme. Quand c'était le dernier, la minuterie s'arrête :
  /// sans cela elle tomberait sur le film lancé le lendemain.
  ///
  /// Entre deux épisodes le suivant est déjà ouvert quand le précédent se
  /// ferme, si bien que le compte ne passe pas par zéro et qu'elle continue.
  void release() {
    if (_players > 0) _players--;
    if (_players == 0) cancel();
  }

  void _expire() {
    _clear();
    _due = true;
    notifyListeners();
  }

  void _clear() {
    _timer?.cancel();
    _timer = null;
    _chosen = null;
    _endsAt = null;
    _due = false;
  }

  @visibleForTesting
  void resetForTest() {
    _clear();
    _players = 0;
  }
}
