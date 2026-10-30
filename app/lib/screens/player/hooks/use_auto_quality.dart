import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/auto_descent.dart';
import '../playback/auto_quality.dart';
import '../playback/auto_trust.dart';

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

/// Une mesure active de la ligne : ce qu'un téléchargement à côté de la
/// lecture a obtenu, et ce que la lecture tirait pendant ce temps — null
/// quand le moteur ne le dit pas.
typedef AutoLineMeasure = ({int spareBps, int? inUseBps});

/// Tient la qualité automatique pendant une lecture (ADR-0056).
///
/// [AutoQuality] décide, cette classe exécute : une fois par seconde elle lit
/// la lecture, et quand la décision tombe elle demande au contrôleur de
/// changer de source — ou, pour remonter, de mesurer d'abord la ligne. Elle ne
/// connaît ni moteur ni serveur : le contrôleur lui donne quatre fonctions.
class AutoQualityPilot {
  AutoQualityPilot({
    required AutoQualityReading Function() read,
    required Future<AutoLineMeasure?> Function(int wantBps) measureLine,
    required Future<bool> Function(AutoTarget target, {required bool urgent})
        move,
    Future<AutoSounding> Function({required bool passive, bool sideMeasure})?
        sound,
    AutoQuality? rules,
    AutoTrust? trust,
    AutoDescentGate? gate,
    DateTime Function() now = DateTime.now,
  })  : _gate = gate ?? AutoDescentGate(),
        _read = read,
        _measureLine = measureLine,
        _move = move,
        _sound = sound,
        _rules = rules ?? AutoQuality(),
        _trust = trust ?? AutoTrust(),
        _now = now;

  final AutoQualityReading Function() _read;
  final Future<AutoLineMeasure?> Function(int wantBps) _measureLine;
  final Future<bool> Function(AutoTarget target, {required bool urgent}) _move;

  /// Sonde la ligne et le serveur au moment de descendre. Sans elle, le
  /// barreau se choisit d'après la pente du tampon. `passive` : ne rien
  /// rendre qui coûte à la ligne ou qui ne vaille pas pour une session à
  /// peine ouverte. `sideMeasure` : mesurer la ligne à côté de la lecture
  /// plutôt que croire ce que le moteur reçoit — un moteur au cache plein ne
  /// reçoit que ce qu'il lit.
  final Future<AutoSounding> Function({required bool passive, bool sideMeasure})?
      _sound;
  final AutoQuality _rules;
  final AutoTrust _trust;
  final AutoDescentGate _gate;
  final DateTime Function() _now;

  Timer? _timer;
  bool _enabled = false;
  bool _busy = false;
  int _maxEncodeHeight = 0;

  /// La plus grande image que le serveur a su encoder assez vite pendant
  /// cette lecture, 0 tant qu'il n'a pas été pris en défaut. Le contrôleur la
  /// rend dans [AutoLadder.maxEncodeHeight] : l'Auto ne remonte pas au-dessus.
  int get maxEncodeHeight => _maxEncodeHeight;

  /// Ce que la ligne porte de ce qui est lu, d'après les derniers relevés ;
  /// null tant que rien n'a été mesuré.
  double? get measuredRatio => _rules.measuredRatio;

  /// Si l'Auto tient la qualité de cette lecture. Un choix dans le menu
  /// Qualité la lui retire, « Auto » la lui rend.
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      _rules.noteChosen(_now());
      _trust.reset();
      // Qui redemande l'Auto veut qu'elle réessaie : le serveur a pu se
      // libérer depuis.
      _maxEncodeHeight = 0;
    }
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
  void noteDisturbance() {
    _gate.reset();
    _rules.noteDisturbance(_now());
  }

  /// Une mise en mémoire tampon vient de commencer en pleine lecture.
  Future<void> noteStall() async {
    if (!_enabled || _busy) return;
    final reading = _read();
    if (!reading.eligible || !reading.playing) return;
    final now = _now();
    if (_rules.inGrace(now)) {
      await _descendIfStarved();
      return;
    }
    if (!_rules.noteStall(now)) return;
    await _descend(reading, urgent: true);
  }

  /// Une coupure pendant un délai de grâce — au démarrage, après une
  /// recherche. Le tampon vide ne prouve rien, mais ce que le moteur reçoit,
  /// si : une ligne qui livre moins que ce qui est lu ne tiendra pas, et il
  /// n'y a pas à attendre la coupure suivante pour le savoir. Mesuré : un
  /// film à 41 Mbit/s sur une ligne à 5 restait figé dix-huit secondes avant
  /// que l'Auto ait le droit d'agir.
  Future<void> _descendIfStarved() async {
    final sound = _sound;
    if (sound == null) return;
    await _run(() async {
      // Cache plein : le moteur ne télécharge pas à plein débit, la mesure
      // ne dit rien de la ligne.
      if (!_gate.measurable(buffered: _read().buffered)) {
        debugPrint('Auto: coupure sans conséquence, le tampon est plein — '
            'mesure ignorée');
        return;
      }
      final line = (await sound(passive: true)).lineBps;
      if (line == null) return;
      final reading = _read();
      final ladder = reading.ladder;
      // La mesure a pris du temps : un tampon rempli entre-temps l'invalide.
      if (!_gate.measurable(buffered: reading.buffered)) return;
      final starved = ladder.currentKey == null
          ? line < ladder.sendingBps * AutoTrust.directShortfall
          : ladder.starves(line);
      if (!starved) {
        _gate.noteFine();
        return;
      }
      final target = _gatedTarget(ladder, line, reason: 'coupure');
      if (target == null) return;
      debugPrint('Auto: ligne mesurée à ${(line / 1e6).toStringAsFixed(1)} '
          'Mbit/s — passage de ${ladder.currentKey ?? 'direct'} à $target '
          '(coupure, mesure confirmée)');
      if (await _move(target, urgent: true)) _noteMoved(up: false);
    }, quietOnFailure: false);
  }

  /// Le barreau à viser sur une mesure basse, une fois que les règles de
  /// [AutoDescentGate] l'autorisent : mesure confirmée par une deuxième,
  /// descente d'un seul barreau sauf trois mesures concordantes. Null (avec sa
  /// raison au journal) tant qu'elles ne le permettent pas.
  AutoTarget? _gatedTarget(AutoLadder ladder, int line,
      {required String reason, bool cool = false}) {
    final now = _now();
    final mbit = (line / 1e6).toStringAsFixed(1);
    if (cool && _gate.coolingDown(now)) {
      debugPrint('Auto: ligne mesurée à $mbit Mbit/s — descente différée, '
          'la dernière est trop récente ($reason)');
      return null;
    }
    _gate.noteLow(now, line);
    if (!_gate.confirmed(now)) {
      debugPrint('Auto: ligne mesurée à $mbit Mbit/s — à confirmer par une '
          'deuxième mesure avant de descendre ($reason)');
      return null;
    }
    final capacity = _gate.confirmedBps(now) ?? line;
    final target = _gate.confirmedBig(now)
        ? ladder.downTo(capacity)
        : ladder.oneRungDown();
    return target;
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
        // Une mesure récente a disculpé la ligne : c'est le moteur qui laisse
        // fondre son cache plein, pas elle qui manque.
        if (!_trust.slopeCounts(_now())) return;
        await _descend(reading, urgent: false);
      case AutoVerdict.canClimb:
        await _climb(reading);
    }
  }

  Future<void> _descend(AutoQualityReading reading,
      {required bool urgent}) async {
    await _run(() async {
      // Pendant une coupure le cache est vide, et le moteur tire tout ce que
      // la ligne porte : ce qu'il reçoit la mesure. Sur une pente, il peut
      // tenir un cache plein qui ne reçoit que ce qu'il lit — seule une mesure
      // à côté dit alors ce que la ligne porterait.
      final sounding =
          await _sound?.call(passive: false, sideMeasure: !urgent) ??
              const AutoSounding();
      // La sonde a pris une seconde ou deux : l'échelle se relit.
      final ladder = _sound == null ? reading.ladder : _read().ladder;
      if (sounding.encoderBehind && await _leaveTheEncoder(ladder)) return;
      final target = _aim(ladder, sounding, urgent: urgent);
      if (target == null) {
        // Rien à tenter avant le prochain délai de grâce.
        _rules.noteDisturbance(_now());
        return;
      }
      final moved = await _move(target, urgent: urgent);
      if (moved) {
        _noteMoved(up: false);
      } else {
        _rules.noteDisturbance(_now());
      }
    });
  }

  /// Un changement de source vient d'aboutir. [carried] : la mesure qui l'a
  /// décidé dit déjà que la ligne porte la nouvelle source.
  void _noteMoved({required bool up, bool carried = false}) {
    final now = _now();
    _rules.noteMoved(now, up: up);
    if (up) {
      _gate.reset();
    } else {
      _gate.noteDescended(now);
    }
    _trust.reset();
    if (carried) _trust.noteCarried(now);
  }

  /// Le serveur n'encode pas assez vite : si la ligne porte le fichier tel
  /// quel, c'est lui qu'il faut lire — il ne coûte rien au serveur. Rend vrai
  /// quand la lecture y est passée.
  Future<bool> _leaveTheEncoder(AutoLadder ladder) async {
    if (ladder.up(1 << 62)?.isDirect != true) return false;
    final measure = await _measureLine(ladder.climbDemandBps);
    if (measure == null) return false;
    final capacity = measure.spareBps + (measure.inUseBps ?? 0);
    if (ladder.up(capacity)?.isDirect != true) return false;
    debugPrint('Auto: le serveur n’encode pas '
        '${ladder.currentKey} assez vite, et la ligne porte '
        '${(capacity / 1e6).toStringAsFixed(1)} Mbit/s — retour au fichier');
    if (!await _move(const AutoTarget.direct(), urgent: true)) return false;
    _noteMoved(up: true, carried: true);
    return true;
  }

  /// Le barreau à viser, d'après ce que la sonde a trouvé.
  AutoTarget? _aim(AutoLadder ladder, AutoSounding sounding,
      {required bool urgent}) {
    final from = ladder.currentKey ?? 'direct';
    final why = urgent ? ' (coupure)' : '';

    if (sounding.encoderBehind) {
      final target = ladder.smallerPicture();
      // Ni ce barreau ni rien de plus grand ne sera retenté.
      final height = ladder.currentHeight;
      if (height > 0) {
        _maxEncodeHeight = target?.tier?.height ?? height;
      }
      debugPrint('Auto: le serveur n’encode pas $from assez vite — '
          '${target == null ? 'rien de plus petit à demander' : 'passage à $target'}'
          '$why. La ligne n’y est pour rien.');
      return target;
    }

    final now = _now();
    final direct = ladder.currentKey == null;
    final line = sounding.lineBps;
    if (line == null) {
      // Le Direct Play ne se quitte pas sur une supposition : une pente sans
      // mesure ne prouve rien (voir [AutoTrust]), et quelques coupures se
      // laissent passer avant de l'accuser à l'aveugle.
      if (direct &&
          (!urgent || _trust.stallTolerated(now, direct: true))) {
        debugPrint('Auto: ligne non mesurée — on reste en direct$why');
        return null;
      }
      // Sans mesure, rien ne justifie de sauter des barreaux ni de redescendre
      // juste après une descente : un cran, après un délai.
      if (!urgent && _gate.coolingDown(now)) {
        debugPrint('Auto: descente différée, la dernière est trop récente');
        return null;
      }
      final target = ladder.oneRungDown();
      if (target != null) {
        debugPrint('Auto: la ligne porte '
            '${(_rules.fillRatio * 100).round()} % de $from — '
            'passage à $target$why');
      }
      return target;
    }

    final mbit = (line / 1e6).toStringAsFixed(1);
    if (ladder.carries(line)) {
      // La ligne tient ce qui est lu : sur une pente, c'est le cache du
      // moteur qui fond, et elle n'est plus accusée de quelque temps. Sur une
      // coupure, un accroc ou une scène plus lourde que la moyenne du
      // fichier : on en laisse passer, puis un cran de moins.
      _trust.noteCarried(now);
      _gate.noteFine();
      if (!urgent || _trust.stallTolerated(now, direct: direct)) {
        debugPrint('Auto: ligne mesurée à $mbit Mbit/s, assez pour $from — '
            'on ne change rien$why');
        return null;
      }
      final target = ladder.down(0.9);
      if (target != null) {
        debugPrint('Auto: ligne mesurée à $mbit Mbit/s mais $from coupe '
            'encore — passage à $target$why');
      }
      return target;
    }
    final target = _gatedTarget(ladder, line,
        reason: urgent ? 'coupure' : 'tampon qui fond', cool: !urgent);
    if (target != null) {
      debugPrint('Auto: ligne mesurée à $mbit Mbit/s — '
          'passage de $from à $target$why (mesure confirmée)');
    }
    return target;
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
      //
      // Cette part se lit dans le moteur quand il la donne. Sinon elle se
      // déduit de la pente du tampon — qui date des vingt dernières secondes,
      // pas de l'instant de la mesure. Mesuré : 10,8 Mbit/s trouvés sur une
      // ligne à 5, une remontée à 1080p et une rechute dix secondes après.
      final guessed =
          ((_rules.measuredRatio ?? 1) * reading.speed * ladder.sendingBps)
              .round();
      final measure = await _measureLine(ladder.climbDemandBps);
      final capacity = measure == null
          ? null
          : measure.spareBps + (measure.inUseBps ?? guessed);
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
        // Une fois et demie ce que la nouvelle source demande : la ligne est
        // déjà disculpée pour elle.
        _noteMoved(up: true, carried: true);
      } else {
        _rules.noteClimbRefused(_now());
      }
    });
  }

  /// Une seule action à la fois : les relevés qui tombent pendant une mesure
  /// ou un changement de source décriraient la manœuvre, pas la ligne.
  Future<void> _run(Future<void> Function() action,
      {bool quietOnFailure = true}) async {
    _busy = true;
    try {
      await action();
    } catch (e) {
      // Le message peut porter l'adresse d'un flux, ticket compris.
      debugPrint('Auto: manœuvre abandonnée (${e.runtimeType})');
      if (quietOnFailure) _rules.noteDisturbance(_now());
    } finally {
      _busy = false;
    }
  }
}
