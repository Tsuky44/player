import 'package:flutter/foundation.dart';
import '../models/player_layout.dart';
import '../services/layout_storage.dart';

/// Holds the canonical (persisted) modular player layout for the whole app.
///
/// The Player Studio edits a local draft and only commits it here via
/// [replace] when the user taps "Save". The real player reads [config].
class PlayerLayoutProvider extends ChangeNotifier {
  final LayoutStorage _storage;

  PlayerLayoutConfig _config = PlayerLayoutConfig.standard();
  bool _useModularLayout = false;
  bool _isLoaded = false;

  PlayerLayoutProvider(this._storage) {
    _init();
  }

  PlayerLayoutConfig get config => _config;
  bool get isLoaded => _isLoaded;

  /// When true, the player renders the modular layout instead of the standard
  /// fixed HUD. Defaults to false so the player keeps its original UI.
  bool get useModularLayout => _useModularLayout;

  Future<void> _init() async {
    _config = await _storage.load();
    _useModularLayout = await _storage.loadUseModular();
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setUseModularLayout(bool value) async {
    _useModularLayout = value;
    notifyListeners();
    await _storage.saveUseModular(value);
  }

  /// Persist and broadcast a brand new layout (used by "Save Layout").
  Future<void> replace(PlayerLayoutConfig config) async {
    _config = config;
    notifyListeners();
    await _storage.save(config);
  }

  /// Restore the standard default layout and disable modular mode.
  Future<void> reset() async {
    _config = PlayerLayoutConfig.standard();
    _useModularLayout = false;
    notifyListeners();
    await _storage.save(_config);
    await _storage.saveUseModular(false);
  }
}
