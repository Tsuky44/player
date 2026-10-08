import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/models.dart';
import '../web_quality.dart';

/// Si le lecteur peut descendre de lui-même sur l'échelle des débits.
///
/// Un réglage de l'appareil et non du compte : c'est la ligne au bout de
/// laquelle cet appareil se trouve qui ne suit pas, pas la personne. Voir
/// ADR-0004 et ADR-0053.
abstract final class AdaptiveQualityPreference {
  static const String _key = 'adaptive_quality';

  static bool _enabled = true;

  /// Activé d'office : une lecture qui se coupe toutes les trente secondes est
  /// une panne, et le remède existait déjà dans le menu Qualité — encore
  /// fallait-il savoir qu'il était là.
  static bool get enabled => _enabled;

  /// Lit le réglage enregistré. Une fois, au démarrage.
  static Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_key) ?? true;
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

/// Décide quand la connexion ne tient manifestement pas le débit demandé, et
/// quel barreau de l'échelle demander à la place (ADR-0053).
///
/// La preuve est la même que celle de `CachePausePolicy` : le lecteur garde
/// des minutes d'avance, et un tampon vide en pleine lecture dit que le débit
/// reçu est passé sous celui du film. Une coupure seule est un accroc ; trois
/// rapprochées, c'est la ligne.
///
/// Le lecteur ne remonte jamais de lui-même : rien ne dit qu'une ligne qui
/// tient 4 Mbit/s en tiendrait 10, et un aller-retour entre deux barreaux
/// serait pire que le plus bas des deux.
class AdaptiveQuality {
  AdaptiveQuality({
    this.stallsToAct = 3,
    this.window = const Duration(minutes: 3),
    this.grace = const Duration(seconds: 15),
  }) : assert(stallsToAct > 0);

  /// Combien de coupures dans [window] accusent la connexion.
  final int stallsToAct;
  final Duration window;

  /// Après une recherche, un changement de piste ou de qualité, une reprise :
  /// le tampon qui se vide est celui que le lecteur vient de jeter.
  final Duration grace;

  /// La part du débit en cours qu'un barreau ne doit pas dépasser pour valoir
  /// la peine d'être essayé. Juste en dessous, la ligne ne suivrait pas mieux.
  static const double stepRatio = 0.7;

  final List<DateTime> _stalls = [];
  DateTime? _disturbedAt;
  bool _userChose = false;

  /// Le lecteur vient de vider son tampon de lui-même.
  void noteDisturbance(DateTime now) => _disturbedAt = now;

  /// Un choix fait dans le menu Qualité l'emporte jusqu'à la fin de cette
  /// lecture : redescendre derrière quelqu'un qui vient de remonter, ce serait
  /// lui reprendre la main.
  void noteUserChoice() {
    _userChose = true;
    _stalls.clear();
  }

  /// Une mise en mémoire tampon en pleine lecture. Renvoie `true` quand elle
  /// fait la preuve : c'est le moment de descendre.
  bool noteStall(DateTime now) {
    if (_userChose) return false;
    final disturbed = _disturbedAt;
    if (disturbed != null && now.difference(disturbed) < grace) return false;

    _stalls
      ..removeWhere((at) => now.difference(at) > window)
      ..add(now);
    if (_stalls.length < stallsToAct) return false;

    // La descente qui suit est elle-même un changement de qualité, et le
    // nouveau barreau repart d'un compte vierge.
    _stalls.clear();
    _disturbedAt = now;
    return true;
  }

  /// Le barreau à demander à la place de ce qui est lu, ou null au bas de
  /// l'échelle.
  ///
  /// [currentKey] est le barreau en cours, null en Direct Play. [demandBps]
  /// est le débit du fichier quand le moteur le connaît. Sans l'un ni l'autre,
  /// le barreau natif de la source sert de plafond : un remux pèse presque
  /// toujours plusieurs fois son débit.
  static QualityTier? stepDown({
    required List<QualityTier> ladder,
    required String? currentKey,
    required int sourceHeight,
    int? demandBps,
  }) {
    final rungs = [...ladder.where((t) => t.bitrateBps > 0)]
      ..sort((a, b) => b.bitrateBps.compareTo(a.bitrateBps));
    if (rungs.isEmpty) return null;

    final current =
        rungs.where((t) => t.key == currentKey).map((t) => t.bitrateBps);
    final int ceiling;
    if (current.isNotEmpty) {
      ceiling = (current.first * stepRatio).floor();
    } else if (currentKey == null && demandBps != null && demandBps > 0) {
      ceiling = (demandBps * stepRatio).floor();
    } else {
      final native = qualityForSourceHeight(sourceHeight);
      final nativeRung = rungs.where((t) => t.key == native);
      ceiling = nativeRung.isNotEmpty
          ? nativeRung.first.bitrateBps
          : rungs.first.bitrateBps;
    }

    for (final rung in rungs) {
      if (rung.key != currentKey && rung.bitrateBps <= ceiling) return rung;
    }
    return null;
  }
}
