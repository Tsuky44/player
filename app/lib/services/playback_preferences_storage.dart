import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Persisted playback preferences (default audio language, etc.).
class PlaybackPreferencesStorage {
  static const String _defaultAudioLangKey = 'playback_default_audio_lang';

  /// Two-letter ISO code (e.g. "fr"), or null for file default track.
  Future<String?> loadDefaultAudioLang() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_defaultAudioLangKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return normalizeLangCode(raw);
  }

  Future<void> saveDefaultAudioLang(String? lang) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = lang == null ? null : normalizeLangCode(lang);
    if (normalized == null || normalized.isEmpty) {
      await prefs.remove(_defaultAudioLangKey);
    } else {
      await prefs.setString(_defaultAudioLangKey, normalized);
    }
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
