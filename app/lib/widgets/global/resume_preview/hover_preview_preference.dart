import 'package:shared_preferences/shared_preferences.dart';

import '../../../utils/app_platform.dart';

/// Si le survol d'une carte « Reprendre » ouvre son aperçu.
///
/// Un réglage de l'appareil : c'est la souris de cet ordinateur qui déclenche
/// l'aperçu, et ce qui est agréable sur un grand écran peut gêner sur un petit.
abstract final class HoverPreviewPreference {
  static const String _key = 'resume_hover_preview';

  static bool _enabled = true;

  /// Seuls un ordinateur et un navigateur ont une souris qui survole : un
  /// téléphone n'a pas de survol, un téléviseur n'a que le focus.
  static bool get supported => AppPlatform.isDesktop || AppPlatform.isWeb;

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
