import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ce que l'app rapatrie toute seule.
enum AutoDownloadMode {
  /// Rien. Seul ce qu'on demande explicitement descend.
  off,

  /// Une réserve d'avance sur la série en cours : dès qu'il reste moins de
  /// [DownloadPreferences.keepAhead] épisodes non vus sur l'appareil, les
  /// suivants descendent.
  keepAhead,

  /// Toute la série, dès qu'un seul de ses épisodes a été téléchargé.
  wholeShow,
}

/// Que faire quand le réseau se paie à l'octet.
enum MeteredPolicy {
  /// Demander, avec ce que ça coûte écrit noir sur blanc. Par défaut.
  ask,

  /// Télécharger quand même, sans poser la question.
  always,

  /// Ne jamais télécharger là-dessus : ce qui est en file attend le Wi-Fi.
  never,
}

/// Les réglages de téléchargement de **cet appareil**.
///
/// Ils vivent ici et pas sur le compte, comme le profil de lecture
/// (ADR-0004) : un téléphone en 4G et un ordinateur de bureau relié par câble
/// n'ont rien à décider en commun, et c'est précisément l'appareil qui paie.
///
/// Un [ChangeNotifier] plutôt qu'une classe statique parce que trois écrans
/// regardent ces valeurs en même temps — les réglages, l'écran des
/// téléchargements et le bouton de chaque média.
class DownloadPreferences extends ChangeNotifier {
  DownloadPreferences._();

  static final DownloadPreferences instance = DownloadPreferences._();

  static const String _modeKey = 'downloads_auto_mode';
  static const String _keepAheadKey = 'downloads_keep_ahead';
  static const String _meteredKey = 'downloads_metered_policy';

  /// Combien d'épisodes d'avance la réserve vise, quand rien n'a été choisi.
  ///
  /// Quatre : de quoi tenir un trajet sans y penser, sans occuper le disque
  /// d'une saison entière qu'on ne regardera peut-être pas.
  static const int defaultKeepAhead = 4;

  /// Bornes du réglage. Zéro désactiverait la réserve en douce alors qu'il y a
  /// une option pour ça, et au-delà d'une dizaine on télécharge une saison :
  /// c'est le bouton « télécharger la saison » qu'on veut, pas une réserve.
  static const int minKeepAhead = 1;
  static const int maxKeepAhead = 10;

  AutoDownloadMode _mode = AutoDownloadMode.keepAhead;
  int _keepAhead = defaultKeepAhead;
  MeteredPolicy _metered = MeteredPolicy.ask;

  /// Autorisation donnée à la main pour cette session seulement.
  ///
  /// « Télécharger quand même » répond pour maintenant, pas pour toujours : le
  /// réglage permanent existe à côté, dans les paramètres, et c'est là qu'on
  /// s'engage.
  bool _meteredAllowedThisSession = false;

  AutoDownloadMode get mode => _mode;
  int get keepAhead => _keepAhead;
  MeteredPolicy get meteredPolicy => _metered;
  bool get isAutoEnabled => _mode != AutoDownloadMode.off;

  /// Faut-il poser la question avant de télécharger sur un réseau facturé ?
  bool get shouldAskOnMetered =>
      _metered == MeteredPolicy.ask && !_meteredAllowedThisSession;

  /// A-t-on le droit de transférer maintenant sur un réseau facturé ?
  ///
  /// [MeteredPolicy.ask] répond non tant que personne n'a répondu : la file
  /// attend, visiblement, plutôt que de partir sur un doute.
  bool get allowsMeteredNow =>
      _metered == MeteredPolicy.always || _meteredAllowedThisSession;

  /// Relit les réglages. Appelé une fois au démarrage, avant la première image.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _mode = _modeFromName(prefs.getString(_modeKey));
      _keepAhead = _clampKeepAhead(prefs.getInt(_keepAheadKey));
      _metered = _meteredFromName(prefs.getString(_meteredKey));
    } catch (_) {
      // Des réglages illisibles valent les réglages par défaut : ce n'est pas
      // une raison pour que l'app démarre sans téléchargements.
    }
    notifyListeners();
  }

  Future<void> setMode(AutoDownloadMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    await _write((prefs) => prefs.setString(_modeKey, mode.name));
  }

  Future<void> setKeepAhead(int count) async {
    final value = _clampKeepAhead(count);
    if (_keepAhead == value) return;
    _keepAhead = value;
    notifyListeners();
    await _write((prefs) => prefs.setInt(_keepAheadKey, value));
  }

  Future<void> setMeteredPolicy(MeteredPolicy policy) async {
    if (_metered == policy) return;
    _metered = policy;
    // Choisir « demander » remet la question sur la table, y compris pour la
    // session en cours : c'est ce qu'on vient de demander.
    if (policy != MeteredPolicy.always) _meteredAllowedThisSession = false;
    notifyListeners();
    await _write((prefs) => prefs.setString(_meteredKey, policy.name));
  }

  /// « Télécharger quand même », depuis la boîte de dialogue. Vaut jusqu'à la
  /// fermeture de l'app.
  void allowMeteredForSession() {
    if (_meteredAllowedThisSession) return;
    _meteredAllowedThisSession = true;
    notifyListeners();
  }

  Future<void> _write(Future<void> Function(SharedPreferences) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // Un réglage qui n'a pas pu s'écrire s'applique quand même à la session.
    }
  }

  static int _clampKeepAhead(int? value) {
    if (value == null) return defaultKeepAhead;
    return value.clamp(minKeepAhead, maxKeepAhead);
  }

  static AutoDownloadMode _modeFromName(String? name) {
    for (final mode in AutoDownloadMode.values) {
      if (mode.name == name) return mode;
    }
    return AutoDownloadMode.keepAhead;
  }

  static MeteredPolicy _meteredFromName(String? name) {
    for (final policy in MeteredPolicy.values) {
      if (policy.name == name) return policy;
    }
    return MeteredPolicy.ask;
  }
}
