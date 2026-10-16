/// Ce qu'une mesure de la ligne disculpe, et pour combien de temps
/// (ADR-0065).
///
/// Un tampon qui fond n'accuse la ligne que si le moteur essaie de le
/// remplir. Or chaque moteur borne le sien : mpv en octets, ExoPlayer entre un
/// plancher et un plafond. Un cache plein qui fond le temps de se recharger,
/// ou qui tient moins de secondes d'une scène plus lourde, a la pente d'une
/// ligne trop lente — et l'Auto quittait le Direct Play pour une ligne qui
/// portait le fichier. Seule une mesure à côté de la lecture le dit ; une fois
/// faite, cette classe s'en souvient.
class AutoTrust {
  AutoTrust({this.window = const Duration(minutes: 3)});

  /// Combien de temps une mesure vaut, et sur quoi les coupures se comptent.
  final Duration window;

  /// Les coupures qu'une ligne qui porte ce qui est lu laisse passer sur
  /// [window]. Le Direct Play en laisse davantage : le quitter coûte un
  /// encodage au serveur et de la finesse à l'image, et une coupure sur une
  /// ligne qui le porte vient d'un pic du fichier, pas d'elle.
  static const int toleratedDirectStalls = 2;
  static const int toleratedTierStalls = 1;

  /// Pendant un délai de grâce, le Direct Play ne se quitte que sur une ligne
  /// qui livre moins de cette part du fichier : juste après une ouverture, le
  /// moteur reçoit encore moins que ce que la ligne porte.
  static const double directShortfall = 0.8;

  DateTime? _carriedAt;
  final List<DateTime> _stalls = [];

  /// Une mesure vient de dire que la ligne porte ce qui est lu, marge
  /// comprise.
  void noteCarried(DateTime now) => _carriedAt = now;

  /// Si la pente du tampon peut accuser la ligne : pas tant qu'une mesure
  /// récente l'a disculpée.
  bool slopeCounts(DateTime now) {
    final carried = _carriedAt;
    return carried == null || now.difference(carried) > window;
  }

  /// Une coupure sur une ligne qui porte ce qui est lu, ou qu'on n'a pas pu
  /// mesurer. Rend vrai quand elle passe encore ; faux quand elle est de trop,
  /// et que la lecture doit descendre.
  bool stallTolerated(DateTime now, {required bool direct}) {
    _stalls
      ..removeWhere((at) => now.difference(at) > window)
      ..add(now);
    final tolerated = direct ? toleratedDirectStalls : toleratedTierStalls;
    if (_stalls.length <= tolerated) return true;
    _stalls.clear();
    return false;
  }

  /// La lecture a changé de source : ce qu'on savait ne vaut plus pour elle.
  void reset() {
    _carriedAt = null;
    _stalls.clear();
  }
}
