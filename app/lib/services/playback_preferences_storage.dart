import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/playback_preferences.dart';
import 'api_client.dart';

/// Les réglages de lecture qui tiennent au goût de la personne — langue audio
/// par défaut, saut d'intro automatique.
///
/// Ils appartiennent au **compte** et suivent la personne d'un appareil à
/// l'autre (ADR-0043). L'appareil en garde une copie, lue sans attendre et
/// valable hors ligne ; le serveur tient la référence. Ce qui dépend du
/// matériel (décodeur, fréquence d'écran, téléchargements) reste sur
/// l'appareil et ne passe pas par ici (ADR-0004).
class PlaybackPreferencesStorage {
  static const String _defaultAudioLangKey = 'playback_default_audio_lang';
  static const String _autoSkipIntroKey = 'playback_auto_skip_intro';

  /// Ce qui a changé ici et n'a pas encore atteint le serveur : la clé du
  /// compte, puis les champs concernés. Voir [_pushPending].
  static const String _pendingKey = 'playback_preferences_pending';

  // Les noms des champs côté serveur.
  static const String _autoSkipIntroField = 'auto_skip_intro';
  static const String _defaultAudioLangField = 'default_audio_lang';

  /// Whether an intro skips itself when the skip button has been up for a few
  /// seconds without anyone touching anything.
  ///
  /// Off by default, unlike the next episode: advancing at the end of an
  /// episode continues what was asked for, while jumping over an intro skips
  /// part of the thing being watched — a recap is sometimes the point. Anyone
  /// who never wants to see one turns this on once.
  static bool _autoSkipIntro = false;

  static bool get autoSkipIntro => _autoSkipIntro;

  /// Avance chaque fois que le compte a apporté une valeur différente de
  /// celle de l'appareil : un écran de réglages ouvert s'y abonne pour ne pas
  /// continuer d'afficher l'ancienne.
  static final ValueNotifier<int> accountRevision = ValueNotifier<int>(0);

  static ApiClient? _account;
  static String? _accountKey;

  /// Reads the cached preferences the player needs synchronously. Call once at
  /// startup, before a media opens.
  static Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoSkipIntro = prefs.getBool(_autoSkipIntroKey) ?? false;
    } catch (_) {
      _autoSkipIntro = false;
    }
  }

  /// Rattache les réglages au compte connecté et les aligne sur lui.
  ///
  /// [accountKey] distingue un compte d'un autre sur cet appareil (serveur et
  /// utilisateur) : un changement en attente pour un compte ne part jamais
  /// vers un autre.
  static Future<void> bindAccount(ApiClient api, String accountKey) {
    _account = api;
    _accountKey = accountKey;
    return syncWithAccount();
  }

  /// Plus personne de connecté : les réglages redeviennent ceux de l'appareil.
  static void unbindAccount() {
    _account = null;
    _accountKey = null;
  }

  /// Aligne l'appareil et le compte.
  ///
  /// Ce qui a été changé ici sans atteindre le serveur part d'abord, champ par
  /// champ. Un compte qui n'a jamais rien enregistré reçoit les réglages de
  /// l'appareil plutôt que de les écraser avec ses valeurs par défaut. Dans
  /// tous les autres cas, c'est le compte qui a raison.
  ///
  /// Un échec ne change rien : la copie locale continue de servir.
  static Future<void> syncWithAccount() async {
    final api = _account;
    final key = _accountKey;
    if (api == null || key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      var remote = await api.getPlaybackPreferences();
      if (_accountKey != key) return;

      var fields = _pendingFieldsFor(prefs, key);
      if (!remote.isSaved) {
        fields = {_autoSkipIntroField, _defaultAudioLangField};
      }
      if (fields.isNotEmpty) {
        remote = await api.updatePlaybackPreferences(_payload(prefs, fields));
        if (_accountKey != key) return;
      }
      // Sans champ en attente pour ce compte, une trace laissée par un autre
      // ne vaut plus rien : la copie locale va être remplacée.
      await prefs.remove(_pendingKey);
      await _applyAccount(prefs, remote);
    } catch (e) {
      debugPrint('PlaybackPreferencesStorage.syncWithAccount: $e');
    }
  }

  static Future<void> setAutoSkipIntro(bool value) async {
    _autoSkipIntro = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoSkipIntroKey, value);
    } catch (_) {
      // A preference that could not be stored still applies to this session.
    }
    unawaited(_pushPending(_autoSkipIntroField));
  }

  /// Two-letter ISO code (e.g. "fr"), or null for file default track.
  Future<String?> loadDefaultAudioLang() async {
    final prefs = await SharedPreferences.getInstance();
    return _readAudioLang(prefs);
  }

  Future<void> saveDefaultAudioLang(String? lang) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeAudioLang(prefs, lang);
    unawaited(_pushPending(_defaultAudioLangField));
  }

  static String? _readAudioLang(SharedPreferences prefs) {
    final raw = prefs.getString(_defaultAudioLangKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return normalizeLangCode(raw);
  }

  static Future<void> _writeAudioLang(
      SharedPreferences prefs, String? lang) async {
    final normalized = lang == null ? null : normalizeLangCode(lang);
    if (normalized == null || normalized.isEmpty) {
      await prefs.remove(_defaultAudioLangKey);
    } else {
      await prefs.setString(_defaultAudioLangKey, normalized);
    }
  }

  /// Note [field] comme changé ici, puis tente de l'envoyer au compte.
  ///
  /// La note est écrite avant l'envoi : si le serveur est injoignable, ou si
  /// l'app se ferme entre les deux, la prochaine synchronisation saura que
  /// c'est l'appareil qui porte la valeur récente et non le compte.
  static Future<void> _pushPending(String field) async {
    final api = _account;
    final key = _accountKey;
    if (api == null || key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final fields = {..._pendingFieldsFor(prefs, key), field};
      await prefs.setStringList(_pendingKey, [key, ...fields]);
      await api.updatePlaybackPreferences(_payload(prefs, fields));
      // Un autre réglage a pu changer pendant l'envoi : sa note reste.
      final left = _pendingFieldsFor(prefs, key).difference(fields);
      if (left.isEmpty) {
        await prefs.remove(_pendingKey);
      } else {
        await prefs.setStringList(_pendingKey, [key, ...left]);
      }
    } catch (e) {
      debugPrint('PlaybackPreferencesStorage._pushPending: $e');
    }
  }

  static Set<String> _pendingFieldsFor(SharedPreferences prefs, String key) {
    final pending = prefs.getStringList(_pendingKey);
    if (pending == null || pending.isEmpty || pending.first != key) {
      return <String>{};
    }
    return pending.skip(1).toSet();
  }

  static Map<String, Object> _payload(
      SharedPreferences prefs, Set<String> fields) {
    return {
      if (fields.contains(_autoSkipIntroField))
        _autoSkipIntroField: _autoSkipIntro,
      if (fields.contains(_defaultAudioLangField))
        _defaultAudioLangField: _readAudioLang(prefs) ?? '',
    };
  }

  static Future<void> _applyAccount(
    SharedPreferences prefs,
    AccountPlaybackPreferences remote,
  ) async {
    final lang = normalizeLangCode(remote.defaultAudioLang);
    final changed =
        remote.autoSkipIntro != _autoSkipIntro || lang != _readAudioLang(prefs);
    if (!changed) return;
    _autoSkipIntro = remote.autoSkipIntro;
    await prefs.setBool(_autoSkipIntroKey, remote.autoSkipIntro);
    await _writeAudioLang(prefs, lang);
    accountRevision.value++;
  }

  @visibleForTesting
  static void resetForTest() {
    _account = null;
    _accountKey = null;
    _autoSkipIntro = false;
    accountRevision.value = 0;
  }

  /// Picks the best audio track index for [preferredLang], falling back to the
  /// file default track then index 0.
  static int pickAudioIndex(List<MediaAudioTrack> tracks, String? preferredLang) {
    if (tracks.isEmpty) return 0;

    final norm = preferredLang == null ? null : normalizeLangCode(preferredLang);
    if (norm != null) {
      var fallbackIdx = -1;
      for (var i = 0; i < tracks.length; i++) {
        if (normalizeLangCode(tracks[i].language) != norm) continue;
        if (tracks[i].isDefault) return i;
        if (fallbackIdx < 0) fallbackIdx = i;
      }
      if (fallbackIdx >= 0) return fallbackIdx;
    }

    final def = tracks.indexWhere((a) => a.isDefault);
    return def >= 0 ? def : 0;
  }

  /// Normalizes ISO 639 tags to a 2-letter code for matching.
  static String? normalizeLangCode(String? code) {
    if (code == null) return null;
    var c = code.trim().toLowerCase();
    if (c.isEmpty || c == 'und' || c == 'auto' || c == 'no') return null;
    const map = {
      'fra': 'fr', 'fre': 'fr', 'french': 'fr',
      'eng': 'en', 'english': 'en',
      'spa': 'es', 'esp': 'es', 'spanish': 'es',
      'ger': 'de', 'deu': 'de', 'german': 'de',
      'ita': 'it', 'italian': 'it',
      'por': 'pt', 'portuguese': 'pt',
      'jpn': 'ja', 'japanese': 'ja',
      'rus': 'ru', 'russian': 'ru',
      'chi': 'zh', 'zho': 'zh', 'chinese': 'zh',
      'ara': 'ar', 'arabic': 'ar',
      'nld': 'nl', 'dut': 'nl', 'dutch': 'nl',
      'kor': 'ko', 'korean': 'ko',
    };
    if (map.containsKey(c)) return map[c];
    if (c.length > 2) return c.substring(0, 2);
    return c;
  }

  /// Common audio languages offered in settings.
  static const List<({String? code, String label})> audioLanguageOptions = [
    (code: null, label: 'Automatique (piste du fichier)'),
    (code: 'fr', label: 'Français'),
    (code: 'en', label: 'Anglais'),
    (code: 'es', label: 'Espagnol'),
    (code: 'de', label: 'Allemand'),
    (code: 'it', label: 'Italien'),
    (code: 'pt', label: 'Portugais'),
    (code: 'ja', label: 'Japonais'),
  ];
}
