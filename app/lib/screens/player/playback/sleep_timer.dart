import 'dart:async';

import 'package:flutter/foundation.dart';

/// La minuterie de veille : « dans 30 minutes, coupe », ou « encore deux
/// épisodes, puis coupe ».
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
/// En épisodes, elle ne compte que ceux qui vont au bout d'eux-mêmes : passer
/// au suivant à la main, c'est ne pas l'avoir regardé. Et le dernier va
/// jusqu'à la fin du fichier, générique compris — le lecteur ne l'abrège pas
/// pour enchaîner, puisqu'il n'enchaîne pas.
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

  /// Les nombres d'épisodes proposés dans le menu du lecteur.
  static const List<int> episodeChoices = [1, 2, 3, 5];

  Timer? _timer;
  Duration? _chosen;
  DateTime? _endsAt;
  int? _episodesChosen;
  int? _episodesLeft;
  bool _due = false;
  int _players = 0;

  /// La durée choisie tant que la minuterie court, null sinon.
  Duration? get chosen => _chosen;

  /// Le nombre d'épisodes choisi tant que ce compte court, null sinon.
  int? get episodesChosen => _episodesChosen;

  /// Les épisodes qu'il reste à finir, celui à l'écran compris.
  int? get episodesLeft => _episodesLeft;

  /// L'épisode à l'écran est le dernier : à sa fin, le lecteur s'arrête au
  /// lieu d'enchaîner.
  bool get stopsAfterThisEpisode => _episodesLeft == 1;

  bool get isActive => _chosen != null || _episodesLeft != null;

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
    _clear();
    _chosen = duration;
    _endsAt = DateTime.now().add(duration);
    _due = false;
    _timer = Timer(duration, _expire);
    notifyListeners();
  }

  /// Compte en épisodes, celui à l'écran compris : 1 s'arrête à sa fin.
  /// Remplace la durée qui courait, s'il y en avait une.
  void startEpisodes(int count) {
    assert(count > 0);
    _clear();
    _episodesChosen = count;
    _episodesLeft = count;
    notifyListeners();
  }

  /// Un épisode est allé au bout de lui-même. Voir [stopsAfterThisEpisode]
  /// pour savoir, avant d'appeler, si c'était le dernier.
  void episodeFinished() {
    final left = _episodesLeft;
    if (left == null) return;
    if (left <= 1) {
      _clear();
    } else {
      _episodesLeft = left - 1;
    }
    notifyListeners();
  }

  /// Le fichier de l'épisode à l'écran est fini. Vrai une seule fois, quand
  /// c'était le dernier du compte : le lecteur se ferme alors, quoi qu'il ait
  /// à montrer derrière — épisode suivant ou carte de fin de saison, personne
  /// n'est plus là pour y répondre.
  bool takeLastEpisodeEnd() {
    if (_episodesLeft != 1) return false;
    _clear();
    notifyListeners();
    return true;
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
    _episodesChosen = null;
    _episodesLeft = null;
    _due = false;
  }

  @visibleForTesting
  void resetForTest() {
    _clear();
    _players = 0;
  }
}
