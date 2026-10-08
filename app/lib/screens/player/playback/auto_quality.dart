import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/models.dart';
import '../web_quality.dart';

/// Si une lecture démarre en qualité automatique sur cet appareil.
///
/// Un réglage de l'appareil et non du compte : c'est la ligne au bout de
/// laquelle cet appareil se trouve qui porte ou non le débit, pas la personne.
/// Voir ADR-0004 et ADR-0056.
abstract final class AutoQualityPreference {
  static const String _key = 'auto_quality';

  /// Le réglage que celui-ci remplace (« Adapter la qualité à la connexion »,
  /// ADR-0053). Qui l'avait éteint ne voulait pas que le lecteur change de
  /// qualité seul : c'est la même volonté.
  static const String _legacyKey = 'adaptive_quality';

  static bool _enabled = true;

  /// Activé d'office : sur une ligne qui suit, l'Auto ne quitte jamais le
  /// Direct Play, et sur une ligne qui ne suit pas c'est elle le remède.
  static bool get enabled => _enabled;

  /// Lit le réglage enregistré. Une fois, au démarrage.
  static Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_key) ?? prefs.getBool(_legacyKey) ?? true;
    } catch (_) {
      _enabled = true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (_) {
      // Faute de disque, le réglage vaut pour la séance.
    }
  }

  static void resetForTest() => _enabled = true;
}

/// Où l'Auto veut aller : un barreau de l'échelle, ou le fichier tel quel.
class AutoTarget {
  const AutoTarget.direct() : tier = null;
  const AutoTarget.tier(QualityTier this.tier);

  /// Null pour le Direct Play.
  final QualityTier? tier;

  bool get isDirect => tier == null;

  @override
  bool operator ==(Object other) =>
      other is AutoTarget && other.tier?.key == tier?.key;

  @override
  int get hashCode => tier?.key.hashCode ?? 0;

  @override
  String toString() => tier?.key ?? 'direct';
}

/// Ce que dit un relevé de la lecture.
enum AutoVerdict {
  /// Rien à faire.
  steady,

  /// Le tampon fond : la ligne porte moins que ce qui est lu.
  starving,

  /// La lecture tient depuis assez longtemps pour mesurer si la ligne
  /// porterait mieux.
  canClimb,
}

/// La qualité automatique : quand descendre, quand tenter de remonter, et
/// vers quel barreau (ADR-0056).
///
/// Elle décide **avant** la coupure. Chaque seconde, le lecteur lui donne
/// l'avance qu'il a en mémoire ; de la pente de cette avance elle tire ce que
/// la ligne porte, en secondes de film reçues par seconde. Un tampon qui fond
/// dit de combien la ligne est trop courte, donc quel barreau viser d'un seul
/// saut — là où compter les coupures ne savait descendre que d'un cran, après
/// coup.
///
/// La pente ne dit rien d'une ligne qui suit : le serveur ne produit pas plus
/// vite que la lecture, et le tampon reste plat quel que soit le débit en
/// réserve. Pour remonter il faut donc une mesure, que cette classe se borne à
/// demander ([AutoVerdict.canClimb]) ; ses attentes s'allongent à chaque
/// remontée ratée, pour ne pas osciller entre deux barreaux.
class AutoQuality {
  AutoQuality({
    this.grace = const Duration(seconds: 15),
    this.window = const Duration(seconds: 20),
    this.minSpan = const Duration(seconds: 12),
    this.recentWindow = const Duration(seconds: 8),
    this.lowWater = const Duration(seconds: 15),
    this.climbBuffer = const Duration(seconds: 8),
    this.firstClimbWait = const Duration(seconds: 90),
    this.maxClimbWait = const Duration(minutes: 10),
    this.relapseWindow = const Duration(minutes: 3),
  });

  /// Après une recherche, une reprise, un changement de piste ou de source :
  /// le tampon qui se regarnit est celui que le lecteur vient de jeter.
  final Duration grace;

  /// Ce sur quoi la pente du tampon est mesurée, et le minimum pour y croire.
  /// Les segments arrivent par paquets de deux secondes : sur moins que ça, la
  /// pente ne mesure que le dernier paquet.
  final Duration window;
  final Duration minSpan;

  /// Ce sur quoi la ligne est mesurée une fois accusée, pour choisir le
  /// barreau : assez court pour ne voir que la ligne telle qu'elle est devenue.
  final Duration recentWindow;

  /// Sous cette avance, un tampon qui fond demande d'agir. Au-dessus, la ligne
  /// a le temps de se reprendre.
  final Duration lowWater;

  /// L'avance qu'il faut avoir pour dépenser un peu de ligne à la mesurer.
  final Duration climbBuffer;

  /// Le calme exigé avant de tenter une remontée, doublé après chaque
  /// tentative ratée jusqu'à [maxClimbWait].
  final Duration firstClimbWait;
  final Duration maxClimbWait;

  /// Une descente qui suit une remontée d'aussi près la désavoue.
  final Duration relapseWindow;

  /// En dessous, la ligne ne porte pas ce qui est lu.
  static const double starvingRatio = 0.92;

  /// Au-dessus, elle le porte.
  static const double steadyRatio = 0.97;

  /// La part de ce que la ligne porte qu'un barreau peut demander. Viser juste
  /// ferait tenir la lecture sans jamais regarnir le tampon.
  static const double headroom = 0.8;

  /// Ce que la mesure doit dépasser pour justifier un barreau : une fois et
  /// demie son débit. Une remontée ratée se paie d'un changement de plus.
  static const double climbMargin = 1.5;

  /// Ce qu'on suppose d'une ligne qui vient de couper sans que la pente ait
  /// pu être mesurée.
  static const double blindRatio = 0.7;

  final List<({DateTime at, Duration buffered})> _samples = [];
  DateTime? _quietUntil;
  DateTime? _calmSince;
  DateTime? _lastClimbAt;
  late Duration _climbWait = firstClimbWait;
  double? _ratio;

  /// Ce que la ligne porte, rapporté à ce qui est lu : 1 quand elle suit,
  /// 0,5 quand elle n'en livre que la moitié.
  double get fillRatio => _ratio ?? blindRatio;

  /// La même chose, sans supposition : null tant que rien n'a été mesuré, ou
  /// quand la lecture ne reçoit plus rien parce qu'elle a déjà tout.
  double? get measuredRatio => _endInMemory ? 0 : _ratio;
  bool _endInMemory = false;

  /// Le calme exigé avant la prochaine tentative de remontée.
  Duration get climbWait => _climbWait;

  /// Le lecteur vient de vider son tampon de lui-même.
  void noteDisturbance(DateTime now) {
    _samples.clear();
    _ratio = null;
    _endInMemory = false;
    _quietUntil = now.add(grace);
  }

  /// L'Auto vient d'être choisie dans le menu : elle peut mesurer la ligne
  /// dès que la lecture est stable, sans attendre son tour.
  void noteChosen(DateTime now) {
    _climbWait = firstClimbWait;
    _lastClimbAt = null;
    _calmSince = now.subtract(firstClimbWait);
  }

  /// Un changement de qualité vient d'aboutir.
  void noteMoved(DateTime now, {required bool up}) {
    noteDisturbance(now);
    _calmSince = now;
    if (up) {
      _lastClimbAt = now;
      return;
    }
    final climbed = _lastClimbAt;
    _lastClimbAt = null;
    if (climbed != null && now.difference(climbed) <= relapseWindow) {
      // Redescendre aussi vite, c'est que la remontée était de trop.
      _lengthenClimbWait();
    } else {
      // La ligne vient de changer : ce qu'on savait d'elle ne vaut plus.
      _climbWait = firstClimbWait;
    }
  }

  /// La mesure n'a pas justifié de remonter, ou la remontée n'a pas abouti.
  void noteClimbRefused(DateTime now) {
    _calmSince = now;
    _lengthenClimbWait();
  }

  void _lengthenClimbWait() {
    final doubled = _climbWait * 2;
    _climbWait = doubled > maxClimbWait ? maxClimbWait : doubled;
  }

  /// Une mise en mémoire tampon en pleine lecture. Renvoie `true` quand elle
  /// accuse la ligne : c'est le moment de descendre, sans en attendre une
  /// deuxième.
  bool noteStall(DateTime now) {
    final quiet = _quietUntil;
    if (quiet != null && now.isBefore(quiet)) return false;
    _calmSince = now;
    final measured = _ratio ?? blindRatio;
    _ratio = measured < 0.9 ? measured : 0.9;
    return true;
  }

  /// Le relevé d'une seconde de lecture.
  ///
  /// [buffered] est l'avance en mémoire, [remaining] ce qu'il reste du média,
  /// [speed] la vitesse de lecture.
  AutoVerdict noteSample(
    DateTime now, {
    required Duration buffered,
    required Duration remaining,
    required bool playing,
    double speed = 1,
  }) {
    _calmSince ??= now;
    final climbed = _lastClimbAt;
    if (climbed != null && now.difference(climbed) > relapseWindow) {
      // La remontée a tenu : la suivante n'a pas à attendre plus longtemps.
      _lastClimbAt = null;
      _climbWait = firstClimbWait;
    }

    if (!playing) {
      _samples.clear();
      _ratio = null;
      return AutoVerdict.steady;
    }
    _samples
      ..removeWhere((s) => now.difference(s.at) > window)
      ..add((at: now, buffered: buffered));

    final quiet = _quietUntil;
    if (quiet != null && now.isBefore(quiet)) return AutoVerdict.steady;

    final ratio = _ratio = _measure(speed);
    if (ratio == null) return AutoVerdict.steady;

    // La fin du média est déjà en mémoire : le tampon ne peut que fondre, et
    // la ligne n'y est pour rien. Ce n'est pas une raison de rester en bas —
    // mesuré : un barreau à 1 Mbit/s tient tout un film en mémoire en trois
    // minutes, et l'Auto n'en serait jamais remontée.
    _endInMemory = remaining - buffered <= const Duration(seconds: 2);
    if (!_endInMemory && ratio < starvingRatio && buffered < lowWater) {
      // La fenêtre entière a suffi à accuser la ligne, mais elle mêle l'avant
      // et l'après : mesuré, une ligne tombée à la moitié du débit s'y lisait
      // à 89 %, et le barreau choisi était encore trop lourd. Pour viser, ce
      // sont les dernières secondes qui comptent.
      final recent = _measure(speed, over: recentWindow);
      if (recent != null && recent < ratio) _ratio = recent;
      return AutoVerdict.starving;
    }
    if ((_endInMemory || ratio >= steadyRatio) &&
        buffered >= climbBuffer &&
        now.difference(_calmSince!) >= _climbWait) {
      return AutoVerdict.canClimb;
    }
    return AutoVerdict.steady;
  }

  /// Les secondes de film reçues par seconde de lecture, ou null tant que la
  /// fenêtre est trop courte.
  ///
  /// La pente se prend entre la moyenne de la première moitié de la fenêtre
  /// et celle de la seconde, pas entre ses deux bouts : un tampon nourri par
  /// segments monte en dents de scie, et deux relevés isolés mesureraient la
  /// dent.
  double? _measure(double speed, {Duration? over}) {
    final last = _samples.isEmpty ? null : _samples.last.at;
    final samples = over == null || last == null
        ? _samples
        : _samples.where((s) => last.difference(s.at) <= over).toList();
    if (samples.length < 4 || speed <= 0) return null;
    final first = samples.first.at;
    final span = samples.last.at.difference(first);
    if (span < (over == null ? minSpan : over * 0.7)) return null;

    final middle = first.add(span ~/ 2);
    var olderSum = 0.0, newerSum = 0.0;
    var olderAt = 0.0, newerAt = 0.0;
    var older = 0, newer = 0;
    for (final sample in samples) {
      final seconds = sample.buffered.inMilliseconds / 1000;
      final at = sample.at.difference(first).inMilliseconds / 1000;
      if (sample.at.isBefore(middle)) {
        olderSum += seconds;
        olderAt += at;
        older++;
      } else {
        newerSum += seconds;
        newerAt += at;
        newer++;
      }
    }
    if (older == 0 || newer == 0) return null;
    // Entre les instants moyens des deux moitiés, pas sur une demi-fenêtre
    // supposée : elles n'ont pas toujours le même nombre de relevés.
    final apart = newerAt / newer - olderAt / older;
    if (apart <= 0) return null;
    final slope = (newerSum / newer - olderSum / older) / apart;
    final received = speed + slope;
    return received <= 0 ? 0 : received / speed;
  }
}

/// Ce que l'Auto sait du média et de ce qui est lu, pour choisir un barreau.
///
/// Un barreau se juge sur ce qu'il demande **réellement** à la ligne, qui
/// n'est pas toujours son débit affiché : le barreau natif de la source est
/// recopié par le serveur quand il le peut, et pèse alors ce que pèse le
/// fichier. D'où [currentBps] et [ceilingBps], que le contrôleur renseigne
/// quand la session dit recopier l'image.
class AutoLadder {
  const AutoLadder({
    required this.tiers,
    required this.currentKey,
    required this.sourceHeight,
    this.sourceBps = 0,
    this.currentBps = 0,
    this.directAllowed = true,
    this.ceilingKey,
    this.ceilingBps = 0,
  });

  /// L'échelle que le serveur annonce pour ce média.
  final List<QualityTier> tiers;

  /// Le barreau lu, null en Direct Play.
  final String? currentKey;
  final int sourceHeight;

  /// Le débit du fichier, 0 quand le serveur ne l'annonce pas.
  final int sourceBps;

  /// Ce qui est envoyé en ce moment quand ce n'est pas le débit du barreau —
  /// une session qui recopie l'image. 0 : s'en tenir au barreau.
  final int currentBps;

  /// Si cet appareil lit le fichier lui-même. Faux dans un navigateur, ou
  /// pour un codec ou une piste audio qu'il ne décode pas : le sommet est
  /// alors [ceilingKey], le barreau que le lecteur avait pris à la place, qui
  /// demande [ceilingBps] s'il est recopié.
  final bool directAllowed;
  final String? ceilingKey;
  final int ceilingBps;

  /// Les barreaux du plus exigeant au moins exigeant ; à débit égal, la plus
  /// grande image d'abord, comme le serveur les range (ADR-0022).
  ///
  /// Sans le barreau natif quand le Direct Play est permis : recopié, il pèse
  /// ce que pèse le fichier, et n'est donc ni une descente ni une étape.
  List<QualityTier> get _rungs {
    final native = qualityForSourceHeight(sourceHeight);
    return [
      ...tiers.where(
          (t) => t.bitrateBps > 0 && !(directAllowed && t.key == native)),
    ]..sort((a, b) {
        final byDemand = _demand(b).compareTo(_demand(a));
        return byDemand != 0 ? byDemand : b.height.compareTo(a.height);
      });
  }

  int _demand(QualityTier tier) =>
      tier.key == ceilingKey && ceilingBps > 0 ? ceilingBps : tier.bitrateBps;

  /// Ce que la lecture en cours demande à la ligne, 0 quand rien ne le dit.
  int get sendingBps => _sending;

  int get _sending {
    if (currentBps > 0) return currentBps;
    if (currentKey == null) return sourceBps;
    final current = tiers.where((t) => t.key == currentKey);
    return current.isEmpty ? 0 : current.first.bitrateBps;
  }

  /// Ce que le Direct Play demande à la ligne. Sans débit annoncé, le double
  /// du plus haut barreau : un fichier que le serveur n'a pas su peser est
  /// supposé lourd, pour ne pas y remonter à tort.
  int _directDemand(List<QualityTier> rungs) =>
      sourceBps > 0 ? sourceBps : rungs.first.bitrateBps * 2;

  /// Le barreau à demander quand la ligne ne porte que [ratio] de ce qui est
  /// lu, ou null au bas de l'échelle.
  AutoTarget? down(double ratio) {
    final rungs = _rungs;
    if (rungs.isEmpty) return null;

    var sending = _sending;
    if (sending <= 0) {
      if (currentKey != null) return null;
      // Un fichier dont le serveur n'annonce pas le débit : il pèse presque
      // toujours au moins ce que pèse le barreau de sa résolution.
      final native = qualityForSourceHeight(sourceHeight);
      final nativeTier =
          tiers.where((t) => t.key == native && t.bitrateBps > 0);
      sending = nativeTier.isNotEmpty
          ? nativeTier.first.bitrateBps
          : rungs.first.bitrateBps;
    }

    final lower = rungs
        .where((t) => t.key != currentKey && _demand(t) < sending)
        .toList();
    if (lower.isEmpty) return null;
    final carried = sending * (ratio < 0.9 ? ratio : 0.9);
    final ceiling = carried * AutoQuality.headroom;
    for (final rung in lower) {
      if (_demand(rung) <= ceiling) return AutoTarget.tier(rung);
    }
    // Même le dernier barreau demande plus que la ligne ne porte : c'est
    // encore lui qui coupera le moins.
    return AutoTarget.tier(lower.last);
  }

  /// Le plus haut que [capacityBps], mesuré sur la ligne, justifie d'aller, ou
  /// null si rien au-dessus de ce qui est lu ne passe.
  AutoTarget? up(int capacityBps) {
    if (currentKey == null) return null;
    final rungs = _rungs;
    if (rungs.isEmpty) return null;

    if (directAllowed &&
        capacityBps >= _directDemand(rungs) * AutoQuality.climbMargin) {
      return const AutoTarget.direct();
    }

    // Au-dessus du fichier, un barreau coûterait un encodage pour demander
    // plus à la ligne que le fichier lui-même. Sans Direct Play, le sommet
    // est le barreau pris à sa place, compté à son rang dans l'échelle.
    var listedCap = 1 << 62;
    if (directAllowed) {
      if (sourceBps > 0) listedCap = sourceBps - 1;
    } else {
      final ceiling = rungs.where((t) => t.key == ceilingKey);
      if (ceiling.isNotEmpty) listedCap = ceiling.first.bitrateBps;
    }
    final sending = _sending;
    for (final rung in rungs) {
      final demand = _demand(rung);
      if (rung.key != currentKey &&
          rung.bitrateBps <= listedCap &&
          demand > sending &&
          demand * AutoQuality.climbMargin <= capacityBps) {
        return AutoTarget.tier(rung);
      }
    }
    return null;
  }

  /// S'il existe quelque chose au-dessus de ce qui est lu.
  bool get canClimb => up(1 << 62) != null;

  /// Le débit qu'il faudrait mesurer pour atteindre le sommet : c'est ce que
  /// la mesure cherche à établir, et rien de plus.
  int get climbDemandBps {
    final rungs = _rungs;
    if (rungs.isEmpty) return 0;
    if (directAllowed) {
      return (_directDemand(rungs) * AutoQuality.climbMargin).round();
    }
    final ceiling = rungs.where((t) => t.key == ceilingKey);
    final top = ceiling.isNotEmpty ? ceiling.first : rungs.first;
    return (_demand(top) * AutoQuality.climbMargin).round();
  }
}
