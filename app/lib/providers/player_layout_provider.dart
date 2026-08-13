import 'package:flutter/foundation.dart';
import '../models/player_layout.dart';
import '../models/player_layout_preset.dart';
import '../providers/auth_provider.dart';
import '../services/api_client.dart';
import '../services/layout_storage.dart';

/// Holds the canonical modular player layout for the whole app.
///
/// Named playeurs live on the user account (server). Each device picks which
/// playeur is active locally, so phone and desktop can share one layout or
/// use different ones from the same list.
class PlayerLayoutProvider extends ChangeNotifier {
  final LayoutStorage _storage;
  final ApiClient _apiClient;

  PlayerLayoutConfig _config = PlayerLayoutConfig.standard();
  bool _useModularLayout = false;
  bool _isLoaded = false;
  bool _isSyncing = false;
  String? _activePresetId;
  List<PlayerLayoutPreset> _presets = const [];
  String? _errorMessage;
  int? _boundUserId;

  PlayerLayoutProvider(this._storage, this._apiClient) {
    _init();
  }

  PlayerLayoutConfig get config => _config;
  bool get isLoaded => _isLoaded;
  bool get isSyncing => _isSyncing;
  /// Only meaningful when [fixedChrome] is null — a fixed chrome is neither
  /// the default HUD nor the modular layer.
  bool get useModularLayout => _useModularLayout;

  /// Non-null when the active playeur is a hand-written, non-editable chrome.
  FixedChromeId? get fixedChrome => _config.fixedChrome;
  String? get activePresetId => _activePresetId;
  List<PlayerLayoutPreset> get presets => _presets;
  String? get errorMessage => _errorMessage;

  PlayerLayoutPreset? get activePreset {
    final id = _activePresetId;
    if (id == null) return null;
    for (final preset in _presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  String get activePresetName => activePreset?.name ?? 'Mon playeur';

  Future<void> _init() async {
    _config = await _storage.load();
    _useModularLayout = await _storage.loadUseModular();
    _activePresetId = await _storage.loadActivePresetId();
    _presets = await _storage.loadPresetsCache();
    _isLoaded = true;
    notifyListeners();
  }

  /// Called by [ChangeNotifierProxyProvider] whenever auth state changes.
  void onAuthChanged(AuthProvider auth) {
    if (!auth.isAuthenticated || auth.currentUser == null) {
      if (_boundUserId != null) {
        _boundUserId = null;
        _clearAccountState();
      }
      return;
    }

    final userId = auth.currentUser!.id;
    if (_boundUserId == userId) return;
    _boundUserId = userId;
    // Defer so ChangeNotifierProxyProvider.update never notifies mid-build.
    Future.microtask(syncFromAccount);
  }

  Future<void> _clearAccountState() async {
    _presets = const [];
    _activePresetId = null;
    _errorMessage = null;
    await _storage.clearAccountCache();
    // Keep the last local layout usable on the login screen / offline.
    Future.microtask(notifyListeners);
  }

  /// Pull account layouts, migrate a local-only layout if needed, then apply
  /// the device-selected playeur.
  Future<void> syncFromAccount() async {
    if (_isSyncing) return;
    _isSyncing = true;
    _errorMessage = null;
    notifyListeners();

    try {
      var remote = await _apiClient.listPlayerLayouts();

      // First login on this account: seed from the local device layout.
      if (remote.isEmpty) {
        final seeded = await _apiClient.createPlayerLayout(
          name: 'Mon playeur',
          config: _config,
          useModular: _useModularLayout,
        );
        remote = [seeded];
      }

      _presets = remote;
      await _storage.savePresetsCache(_presets);

      final preferredId = await _storage.loadActivePresetId();
      final selected = _resolvePreset(preferredId) ?? _presets.first;
      await _applyPreset(selected, persistActiveId: true);
    } catch (e) {
      _errorMessage = 'Sync playeurs impossible';
      debugPrint('PlayerLayoutProvider.syncFromAccount: $e');
      // Keep local cache / current layout usable offline.
      if (_presets.isNotEmpty) {
        final selected =
            _resolvePreset(_activePresetId) ?? _presets.first;
        await _applyPreset(selected, persistActiveId: false);
      }
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  PlayerLayoutPreset? _resolvePreset(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final preset in _presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  Future<void> _applyPreset(
    PlayerLayoutPreset preset, {
    required bool persistActiveId,
  }) async {
    _activePresetId = preset.id;
    _config = preset.config;
    _useModularLayout = preset.useModular;
    if (persistActiveId) {
      await _storage.saveActivePresetId(preset.id);
    }
    await _storage.save(_config);
    await _storage.saveUseModular(_useModularLayout);
  }

  Future<void> selectPreset(String id) async {
    final preset = _resolvePreset(id);
    if (preset == null) return;
    await _applyPreset(preset, persistActiveId: true);
    notifyListeners();
  }

  /// Look up the account's playeur for [chrome], if it already has one.
  PlayerLayoutPreset? presetForFixedChrome(FixedChromeId chrome) {
    for (final preset in _presets) {
      if (preset.config.fixedChrome == chrome) return preset;
    }
    return null;
  }

  /// Switch to the fixed [chrome], creating its playeur on first use.
  ///
  /// A fixed chrome is a playeur of its own, so the user's modular playeurs
  /// are left untouched — going back is just selecting one of them again.
  Future<void> activateFixedChrome(FixedChromeId chrome) async {
    final existing = presetForFixedChrome(chrome);
    if (existing != null) {
      await selectPreset(existing.id);
      return;
    }
    await createPreset(
      name: chrome.label,
      config: PlayerLayoutConfig.fixed(chrome),
      useModular: false,
    );
  }

  Future<void> setUseModularLayout(bool value) async {
    _useModularLayout = value;
    notifyListeners();
    await _storage.saveUseModular(value);
    await _persistActiveToServer();
  }

  /// Persist and broadcast a brand new layout (used by "Save Layout").
  Future<void> replace(PlayerLayoutConfig config) async {
    _config = config;
    notifyListeners();
    await _storage.save(config);
    await _persistActiveToServer();
  }

  Future<void> _persistActiveToServer() async {
    final id = _activePresetId;
    if (id == null || id.isEmpty) return;
    try {
      final updated = await _apiClient.updatePlayerLayout(
        id: id,
        config: _config,
        useModular: _useModularLayout,
      );
      _presets = [
        for (final preset in _presets)
          if (preset.id == id) updated else preset,
      ];
      await _storage.savePresetsCache(_presets);
      notifyListeners();
    } catch (e) {
      debugPrint('PlayerLayoutProvider._persistActiveToServer: $e');
    }
  }

  Future<PlayerLayoutPreset?> createPreset({
    String? name,
    PlayerLayoutConfig? config,
    bool? useModular,
  }) async {
    try {
      final created = await _apiClient.createPlayerLayout(
        name: name?.trim().isNotEmpty == true
            ? name!.trim()
            : _nextDefaultName(),
        config: config ?? PlayerLayoutConfig.standard(),
        useModular: useModular ?? false,
      );
      _presets = [created, ..._presets];
      await _storage.savePresetsCache(_presets);
      await _applyPreset(created, persistActiveId: true);
      notifyListeners();
      return created;
    } catch (e) {
      _errorMessage = 'Création du playeur impossible';
      debugPrint('PlayerLayoutProvider.createPreset: $e');
      notifyListeners();
      return null;
    }
  }

  String _nextDefaultName() {
    const base = 'Playeur';
    var index = _presets.length + 1;
    final names = _presets.map((p) => p.name.toLowerCase()).toSet();
    while (names.contains('$base $index'.toLowerCase())) {
      index++;
    }
    return '$base $index';
  }

  Future<bool> renamePreset(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    try {
      final updated = await _apiClient.updatePlayerLayout(id: id, name: trimmed);
      _presets = [
        for (final preset in _presets)
          if (preset.id == id) updated else preset,
      ];
      await _storage.savePresetsCache(_presets);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('PlayerLayoutProvider.renamePreset: $e');
      return false;
    }
  }

  Future<bool> deletePreset(String id) async {
    if (_presets.length <= 1) return false;
    try {
      await _apiClient.deletePlayerLayout(id);
      _presets = _presets.where((p) => p.id != id).toList();
      await _storage.savePresetsCache(_presets);
      if (_activePresetId == id) {
        await _applyPreset(_presets.first, persistActiveId: true);
      }
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('PlayerLayoutProvider.deletePreset: $e');
      return false;
    }
  }

  /// Duplicate the current playeur under a new name, then select it.
  Future<PlayerLayoutPreset?> duplicateActivePreset({String? name}) {
    return createPreset(
      name: name ?? '$activePresetName (copie)',
      config: _config,
      useModular: _useModularLayout,
    );
  }

  /// Restore the standard default layout on the active playeur.
  Future<void> reset() async {
    _config = PlayerLayoutConfig.standard();
    _useModularLayout = false;
    notifyListeners();
    await _storage.save(_config);
    await _storage.saveUseModular(false);
    await _persistActiveToServer();
  }
}
