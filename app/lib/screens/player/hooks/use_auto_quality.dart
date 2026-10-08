import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/auto_quality.dart';

/// Ce que le pilote lit de la lecture à chaque seconde.
@immutable
class AutoQualityReading {
  const AutoQualityReading({
    required this.eligible,
    required this.playing,
    required this.buffered,
    required this.remaining,
    required this.ladder,
    this.speed = 1,
  });

  /// Faux quand il n'y a rien à piloter : un fichier sur le disque, pas encore
  /// d'image, un changement de source déjà en cours.
  final bool eligible;
  final bool playing;

  /// L'avance en mémoire, et ce qu'il reste du média.
  final Duration buffered;
  final Duration remaining;

  /// L'échelle, et où la lecture s'y trouve.
  final AutoLadder ladder;
  final double speed;
}

/// Tient la qualité automatique pendant une lecture (ADR-0056).
///
/// [AutoQuality] décide, cette classe exécute : une fois par seconde elle lit
/// la lecture, et quand la décision tombe elle demande au contrôleur de
/// changer de source — ou, pour remonter, de mesurer d'abord la ligne. Elle ne
/// connaît ni moteur ni serveur : le contrôleur lui donne trois fonctions.
class AutoQualityPilot {
  AutoQualityPilot({
    required AutoQualityReading Function() read,
    required Future<int?> Function(int wantBps) measureLine,
    required Future<bool> Function(AutoTarget target, {required bool urgent})
        move,
    AutoQuality? rules,
    DateTime Function() now = DateTime.now,
  })  : _read = read,
        _measureLine = measureLine,
        _move = move,
        _rules = rules ?? AutoQuality(),
        _now = now;

  final AutoQualityReading Function() _read;
  final Future<int?> Function(int wantBps) _measureLine;
  final Future<bool> Function(AutoTarget target, {required bool urgent}) _move;
  final AutoQuality _rules;
  final DateTime Function() _now;

  Timer? _timer;
  bool _enabled = false;
  bool _busy = false;

  /// Ce que la ligne porte de ce qui est lu, d'après les derniers relevés ;
  /// null tant que rien n'a été mesuré.
  double? get measuredRatio => _rules.measuredRatio;

  /// Si l'Auto tient la qualité de cette lecture. Un choix dans le menu
  /// Qualité la lui retire, « Auto » la lui rend.
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) _rules.noteChosen(_now());
  }

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Le lecteur vient de vider son tampon de lui-même : recherche, reprise,
  /// changement de piste ou de source.
  void noteDisturbance() => _rules.noteDisturbance(_now());

  /// Une mise en mémoire tampon vient de commencer en pleine lecture.
  Future<void> noteStall() async {
    if (!_enabled || _busy) return;
    final reading = _read();
    if (!reading.eligible || !reading.playing) return;
    if (!_rules.noteStall(_now())) return;
    await _descend(reading, urgent: true);
  }

  /// Un relevé. Appelé chaque seconde par [start] ; public pour les tests.
  Future<void> tick() async {
    if (!_enabled || _busy) return;
    final reading = _read();
    if (!reading.eligible) {
      // Ce qui s'est passé pendant ce temps n'est pas une mesure de la ligne.
      _rules.noteDisturbance(_now());
      return;
    }
    final verdict = _rules.noteSample(
      _now(),
      buffered: reading.buffered,
      remaining: reading.remaining,
      playing: reading.playing,
      speed: reading.speed,
    );
    switch (verdict) {
      case AutoVerdict.steady:
        return;
      case AutoVerdict.starving:
        await _descend(reading, urgent: false);
      case AutoVerdict.canClimb:
        await _climb(reading);
    }
  }

  Future<void> _descend(AutoQualityReading reading,
      {required bool urgent}) async {
    final target = reading.ladder.down(_rules.fillRatio);
    if (target == null) {
      // Au bas de l'échelle : rien à tenter avant le prochain délai de grâce.
      _rules.noteDisturbance(_now());
      return;
    }
    debugPrint('Auto: la ligne porte '
        '${(_rules.fillRatio * 100).round()} % de '
        '${reading.ladder.currentKey ?? 'direct'} — passage à $target'
        '${urgent ? ' (coupure)' : ''}');
    await _run(() async {
      final moved = await _move(target, urgent: urgent);
      if (moved) {
        _rules.noteMoved(_now(), up: false);
      } else {
        _rules.noteDisturbance(_now());
      }
    });
  }

  Future<void> _climb(AutoQualityReading reading) async {
    final ladder = reading.ladder;
    // Déjà au sommet : rien à mesurer.
    if (!ladder.canClimb) return;

    await _run(() async {
      // La mesure ne voit que ce que la lecture laisse : ce qu'elle tire
      // elle-même au même moment fait partie de ce que la ligne porte.
      // Mesuré : 1,7 Mbit/s « libres » sur une ligne à 5, dont la lecture
      // prenait le reste pour remplir son tampon.
      final inUse =
          ((_rules.measuredRatio ?? 1) * reading.speed * ladder.sendingBps)
              .round();
      final spare = await _measureLine(ladder.climbDemandBps);
      final capacity = spare == null ? null : spare + inUse;
      final target = capacity == null ? null : ladder.up(capacity);
      if (target == null) {
        debugPrint('Auto: ligne mesurée à '
            '${capacity == null ? '?' : (capacity / 1e6).toStringAsFixed(1)}'
            ' Mbit/s — on reste à ${ladder.currentKey}');
        _rules.noteClimbRefused(_now());
        return;
      }
      debugPrint('Auto: ligne mesurée à '
          '${(capacity! / 1e6).toStringAsFixed(1)} Mbit/s — '
          'remontée à $target');
      final moved = await _move(target, urgent: false);
      if (moved) {
        _rules.noteMoved(_now(), up: true);
      } else {
        _rules.noteClimbRefused(_now());
      }
    });
  }

  /// Une seule action à la fois : les relevés qui tombent pendant une mesure
  /// ou un changement de source décriraient la manœuvre, pas la ligne.
  Future<void> _run(Future<void> Function() action) async {
    _busy = true;
    try {
      await action();
    } catch (e) {
      // Le message peut porter l'adresse d'un flux, ticket compris.
      debugPrint('Auto: manœuvre abandonnée (${e.runtimeType})');
      _rules.noteDisturbance(_now());
    } finally {
      _busy = false;
    }
  }
}
