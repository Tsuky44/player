/// Ce qui autorise l'Auto à descendre d'un barreau sur une mesure de la ligne.
///
/// Mesuré dans les journaux Windows 1.1.30 (Spider-Man, Direct Play) : « ligne
/// mesurée à 20,8 Mbit/s — passage de direct à 1080p-10m », puis 85 s plus
/// tard « 310 Mbit/s — remontée à direct » ; et une fois « 1,8 Mbit/s — passage
/// à 360p ». Le cache de mpv contenait alors 90 à 120 s. La mesure passive lit
/// ce que le moteur *reçoit* : juste après une recherche, ou avec un cache
/// plein, il ne télécharge pas à plein débit et ce chiffre ne dit rien de la
/// ligne. Une seule mesure suffisait pourtant à descendre, de plusieurs
/// barreaux. Les règles ici valent pour toutes les plateformes, c'est
/// [AutoQualityPilot] qui les applique.
class AutoDescentGate {
  AutoDescentGate({
    this.confirmWindow = const Duration(seconds: 90),
    this.minGap = const Duration(seconds: 3),
    this.cooldown = const Duration(seconds: 30),
    this.fullBuffer = const Duration(seconds: 15),
  });

  /// Sur quelle durée deux mesures basses se confirment l'une l'autre, et
  /// l'écart minimal entre elles : deux relevés du même instant n'en font
  /// qu'un.
  final Duration confirmWindow;
  final Duration minGap;

  /// Le délai minimal entre deux descentes qui ne sont pas des coupures.
  final Duration cooldown;

  /// Au-dessus de cette avance, le moteur n'a aucune raison de télécharger à
  /// plein débit : une mesure basse n'est pas un faux débit de la ligne mais
  /// l'absence de besoin.
  final Duration fullBuffer;

  /// Les mesures basses qu'on accumule avant de descendre, trois pour
  /// autoriser plus d'un barreau d'un coup.
  static const int confirmations = 2;
  static const int bigStepConfirmations = 3;

  final List<({DateTime at, int bps})> _lows = [];
  DateTime? _lastDescentAt;

  /// Si la mesure peut compter : le moteur doit télécharger pour de bon, ce
  /// qui n'est pas le cas avec un tampon plein.
  bool measurable({required Duration buffered}) => buffered < fullBuffer;

  /// Le lecteur a vidé son tampon de lui-même (recherche, reprise) : les
  /// mesures d'avant ne disent rien de la suite.
  void reset() => _lows.clear();

  /// Une mesure vient de dire que la ligne porte moins que ce qui est lu.
  void noteLow(DateTime now, int bps) {
    _lows
      ..removeWhere((l) => now.difference(l.at) > confirmWindow)
      ..add((at: now, bps: bps));
  }

  /// Une mesure vient de dire que la ligne suffit : les basses étaient un
  /// accident.
  void noteFine() => _lows.clear();

  /// Si les mesures basses concordent. Il faut [confirmations] relevés,
  /// espacés d'au moins [minGap].
  bool confirmed(DateTime now) {
    final recent = _recent(now);
    if (recent.length < confirmations) return false;
    return recent.last.at.difference(recent.first.at) >= minGap;
  }

  /// Si assez de mesures concordent pour sauter plusieurs barreaux.
  bool confirmedBig(DateTime now) =>
      confirmed(now) && _recent(now).length >= bigStepConfirmations;

  /// La mesure retenue : la plus haute des basses, la plus prudente.
  int? confirmedBps(DateTime now) {
    final recent = _recent(now);
    if (recent.isEmpty) return null;
    return recent.map((l) => l.bps).reduce((a, b) => a > b ? a : b);
  }

  List<({DateTime at, int bps})> _recent(DateTime now) =>
      _lows.where((l) => now.difference(l.at) <= confirmWindow).toList();

  /// Si on vient de descendre : trop tôt pour juger le barreau d'arrivée.
  bool coolingDown(DateTime now) {
    final last = _lastDescentAt;
    return last != null && now.difference(last) < cooldown;
  }

  /// Une descente vient d'aboutir.
  void noteDescended(DateTime now) {
    _lastDescentAt = now;
    _lows.clear();
  }
}
