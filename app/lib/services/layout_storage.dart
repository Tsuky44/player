import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../models/player_layout.dart';
import '../models/player_layout_preset.dart';

/// Local persistence for Player Studio layouts.
///
/// The active layout is cached for offline playback. The list of named presets
/// is also cached so switching playeurs stays snappy between syncs.
/// The active preset id is **device-local** so phone and desktop can pick
/// different playeurs from the same account.
class LayoutStorage {
  static const String _key = 'player_layout_config_v1';
  static const String _useModularKey = 'player_use_modular_v1';
  static const String _activeIdKey = 'player_layout_active_id_v1';
  static const String _presetsCacheKey = 'player_layout_presets_v1';

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

  Future<String?> loadActivePresetId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_activeIdKey);
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<void> saveActivePresetId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      await prefs.remove(_activeIdKey);
    } else {
      await prefs.setString(_activeIdKey, id);
    }
  }

  Future<List<PlayerLayoutPreset>> loadPresetsCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_presetsCacheKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => PlayerLayoutPreset.fromJson(
                Map<String, dynamic>.from(e),
              ))
          .where((p) => p.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePresetsCache(List<PlayerLayoutPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(presets.map((p) => p.toJson()).toList());
    await prefs.setString(_presetsCacheKey, payload);
  }

  Future<void> clearAccountCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_presetsCacheKey);
    await prefs.remove(_activeIdKey);
  }
}
