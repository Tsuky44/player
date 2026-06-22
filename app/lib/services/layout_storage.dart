import 'package:shared_preferences/shared_preferences.dart';
import '../models/player_layout.dart';

/// Local persistence for the modular player layout.
///
/// The layout is stored as a JSON string under a single key so it can be
/// extended later (e.g. multiple named presets) without schema migrations.
class LayoutStorage {
  static const String _key = 'player_layout_config_v1';
  static const String _useModularKey = 'player_use_modular_v1';

  Future<PlayerLayoutConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      return PlayerLayoutConfig.standard();
    }
    try {
      return PlayerLayoutConfig.decode(raw);
    } catch (_) {
      // Corrupted payload -> fall back to a safe default.
      return PlayerLayoutConfig.standard();
    }
  }

  Future<void> save(PlayerLayoutConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, config.encode());
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// Whether the player should use the modular layout instead of the standard
  /// fixed HUD. Defaults to false (standard UI) for a zero-regression default.
  Future<bool> loadUseModular() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_useModularKey) ?? false;
  }

  Future<void> saveUseModular(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useModularKey, value);
  }
}
