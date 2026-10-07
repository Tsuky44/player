import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// La langue de l'interface : français, la langue d'écriture du code, ou
/// anglais, par le dictionnaire de `en.dart` (ADR-0047).
enum AppLanguage {
  french('fr', 'Français'),
  english('en', 'English');

  const AppLanguage(this.code, this.nativeName);

  final String code;

  /// Le nom de la langue dans cette langue : c'est lui qu'on cherche dans une
  /// liste quand l'interface est dans une langue qu'on ne lit pas.
  final String nativeName;

  static const String _preferenceKey = 'app_language';

  /// Français tant que rien n'a été décidé : c'est aussi ce que voient les
  /// tests, qui cherchent les textes tels qu'ils sont écrits dans le code.
  static final ValueNotifier<AppLanguage> notifier =
      ValueNotifier<AppLanguage>(AppLanguage.french);

  static AppLanguage get current => notifier.value;

  /// Le choix explicite de l'utilisateur, ou null s'il suit l'appareil.
  static AppLanguage? _chosen;

  static AppLanguage? get chosen => _chosen;

  /// Français sur un appareil en français, anglais partout ailleurs.
  static AppLanguage forDevice(Locale locale) =>
      locale.languageCode == 'fr' ? AppLanguage.french : AppLanguage.english;

  /// À appeler une fois au démarrage, avant le premier écran.
  static Future<void> load() async {
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_preferenceKey);
    } catch (_) {
      // Sans préférences lisibles, on suit l'appareil.
    }
    _chosen = _fromCode(saved);
    notifier.value =
        _chosen ?? forDevice(PlatformDispatcher.instance.locale);
  }

  /// Fixe la langue, ou revient à celle de l'appareil avec null.
  static Future<void> choose(AppLanguage? language) async {
    _chosen = language;
    notifier.value =
        language ?? forDevice(PlatformDispatcher.instance.locale);
    try {
      final preferences = await SharedPreferences.getInstance();
      if (language == null) {
        await preferences.remove(_preferenceKey);
      } else {
        await preferences.setString(_preferenceKey, language.code);
      }
    } catch (_) {
      // Le choix vaut pour cette session ; il sera redemandé au prochain
      // lancement si le stockage refuse.
    }
  }

  static AppLanguage? _fromCode(String? code) {
    for (final language in AppLanguage.values) {
      if (language.code == code) return language;
    }
    return null;
  }

  @visibleForTesting
  static void resetForTest() {
    _chosen = null;
    notifier.value = AppLanguage.french;
  }
}
