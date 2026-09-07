import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_account.dart';

/// Le carnet d'adresses de l'app : les serveurs auxquels cet appareil a un
/// compte, celui qui est actif, et les demandes d'accès encore en attente.
///
/// Avant ce registre, l'app tenait une adresse (`server_url`) et un jeton
/// (`auth_token`) : changer de serveur voulait dire écraser les deux, donc se
/// déconnecter du premier. Ici chaque compte garde son jeton dans son coin, et
/// « changer de serveur » n'est qu'un changement de pointeur — d'où le fait
/// qu'on revienne sur l'autre serveur sans retaper quoi que ce soit.
///
/// Ce qui n'est **pas** ici : le moindre lien entre deux comptes. Les serveurs
/// s'ignorent, et c'est l'app seule qui sait qu'ils appartiennent à la même
/// personne. Voir ADR-0013.
class ServerRegistry extends ChangeNotifier {
  static const _storeKey = 'onyx_servers_v1';
  static const _tokenPrefix = 'auth_token_';
  static const _profilePrefix = 'cached_profile_';

  // Clés de l'époque mono-serveur, relues une fois pour la migration.
  static const _legacyUrlKey = 'server_url';
  static const _legacyTokenKey = 'auth_token';
  static const _legacyProfileKey = 'cached_profile';
  static const _legacyUsernameKey = 'last_username';

  final _secureStorage = const FlutterSecureStorage();

  List<ServerAccount> _accounts = const [];
  List<PendingAccessRequest> _pendingRequests = const [];
  String? _activeId;
  bool _loaded = false;

  List<ServerAccount> get accounts => List.unmodifiable(_accounts);
  List<PendingAccessRequest> get pendingRequests =>
      List.unmodifiable(_pendingRequests);
  bool get isLoaded => _loaded;

  ServerAccount? get active {
    final id = _activeId;
    if (id == null) return null;
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  /// Vrai dès qu'il y a de quoi basculer — ce qui décide de l'affichage du
  /// sélecteur : un seul serveur n'a pas besoin d'un menu pour en changer.
  bool get hasMultipleServers => _accounts.length > 1;

  ServerAccount? accountById(String id) {
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  ServerAccount? accountForUrl(String url) {
    final normalized = ServerAccount.normalizeUrl(url);
    for (final account in _accounts) {
      if (account.url == normalized) return account;
    }
    return null;
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storeKey);

    if (raw == null || raw.isEmpty) {
      await _migrateLegacy(prefs);
      _loaded = true;
      return;
    }

    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _accounts = (data['accounts'] as List? ?? const [])
          .map((e) => ServerAccount.fromJson(e as Map<String, dynamic>))
          .toList();
      _pendingRequests = (data['requests'] as List? ?? const [])
          .map((e) => PendingAccessRequest.fromJson(e as Map<String, dynamic>))
          .toList();
      _activeId = data['active'] as String?;
    } catch (_) {
      // Un carnet illisible ne doit pas empêcher l'app de démarrer : elle
      // repart sur l'écran de connexion, ce qui est récupérable.
      _accounts = const [];
      _pendingRequests = const [];
      _activeId = null;
    }
    if (accountById(_activeId ?? '') == null) {
      _activeId = _accounts.isEmpty ? null : _accounts.first.id;
    }
    _loaded = true;
  }

  /// Reprend la session mono-serveur laissée par les versions précédentes.
  ///
  /// Sans cela, la mise à jour déconnecterait tout le monde : l'adresse et le
  /// jeton existent, mais plus personne ne les lit.
  Future<void> _migrateLegacy(SharedPreferences prefs) async {
    final url = prefs.getString(_legacyUrlKey);
    if (url == null || url.isEmpty) return;

    var token = prefs.getString(_legacyTokenKey);
    if (token == null || token.isEmpty) {
      try {
        token = await _secureStorage.read(key: _legacyTokenKey);
      } catch (_) {}
    }
    if (token == null || token.isEmpty) return;

    final username = prefs.getString(_legacyUsernameKey) ?? '';
    final normalized = ServerAccount.normalizeUrl(url);
    final account = ServerAccount(
      id: ServerAccount.idFor(normalized, username),
      url: normalized,
      username: username,
    );

    _accounts = [account];
    _activeId = account.id;
    await _writeToken(account.id, token);

    final profile = prefs.getString(_legacyProfileKey);
    if (profile != null && profile.isNotEmpty) {
      await prefs.setString('$_profilePrefix${account.id}', profile);
    }

    await _persist();

    // Les anciennes clés sont retirées une fois reprises : laisser traîner un
    // jeton que plus personne ne lit, c'est laisser traîner un identifiant.
    await prefs.remove(_legacyTokenKey);
    await prefs.remove(_legacyProfileKey);
    try {
      await _secureStorage.delete(key: _legacyTokenKey);
    } catch (_) {}
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storeKey,
      jsonEncode({
        'active': _activeId,
        'accounts': _accounts.map((e) => e.toJson()).toList(),
        'requests': _pendingRequests.map((e) => e.toJson()).toList(),
      }),
    );
  }

  // ==================== COMPTES ====================

  /// Enregistre un compte et le rend actif. Idempotent : se reconnecter au même
  /// serveur sous le même nom remplace le jeton au lieu d'ajouter une ligne.
  ///
  /// [activate] est mis à faux quand la session arrive pendant qu'on travaille
  /// ailleurs — une demande d'accès approuvée pendant que l'app est ouverte sur
  /// un autre serveur. Le compte entre dans le carnet, mais l'écran ne bouge
  /// pas sous les doigts de l'utilisateur : c'est lui qui bascule quand il veut.
  Future<ServerAccount> remember({
    required String url,
    required String username,
    required String token,
    int? userId,
    String? label,
    bool activate = true,
  }) async {
    final normalized = ServerAccount.normalizeUrl(url);
    final id = ServerAccount.idFor(normalized, username);
    final existing = accountById(id);
    final account = ServerAccount(
      id: id,
      url: normalized,
      username: username,
      userId: userId ?? existing?.userId,
      label: label ?? existing?.label,
    );

    _accounts = [
      for (final other in _accounts)
        if (other.id != id) other,
      account,
    ];
    if (activate || _activeId == null) _activeId = id;
    await _writeToken(id, token);
    // Une demande satisfaite n'a plus lieu d'attendre.
    await dropPendingRequestFor(normalized, username, persist: false);
    await _persist();
    notifyListeners();
    return account;
  }

  /// Bascule sur un compte déjà enregistré. Rend faux quand l'identifiant ne
  /// correspond à rien — un compte supprimé sur un autre appareil, typiquement.
  Future<bool> activate(String id) async {
    if (accountById(id) == null) return false;
    if (_activeId == id) return true;
    _activeId = id;
    await _persist();
    notifyListeners();
    return true;
  }

  /// Change l'adresse d'un compte sans toucher à sa session.
  ///
  /// Le même serveur se joint parfois autrement — l'IP locale hier, un nom de
  /// domaine aujourd'hui. Le jeton, lui, reste valable : c'est le serveur qui
  /// le connaît, pas l'adresse.
  Future<ServerAccount?> updateUrl(String id, String url) async {
    final account = accountById(id);
    if (account == null) return null;
    final normalized = ServerAccount.normalizeUrl(url);
    if (normalized == account.url) return account;

    final token = await tokenFor(id);
    final profile = await readProfile(id);
    await forget(id, persist: false);

    final moved = ServerAccount(
      id: ServerAccount.idFor(normalized, account.username),
      url: normalized,
      username: account.username,
      userId: account.userId,
      label: account.label,
    );
    _accounts = [..._accounts, moved];
    _activeId = moved.id;
    if (token != null) await _writeToken(moved.id, token);
    if (profile != null) await writeProfile(moved.id, profile);
    await _persist();
    notifyListeners();
    return moved;
  }

  Future<void> rename(String id, String? label) async {
    final account = accountById(id);
    if (account == null) return;
    _accounts = [
      for (final other in _accounts)
        if (other.id == id)
          ServerAccount(
            id: other.id,
            url: other.url,
            username: other.username,
            userId: other.userId,
            label: (label == null || label.trim().isEmpty) ? null : label.trim(),
          )
        else
          other,
    ];
    await _persist();
    notifyListeners();
  }

  /// Retire un compte et tout ce qui lui appartient. Quand c'était l'actif, le
  /// suivant prend la place : se déconnecter d'un serveur ne doit pas renvoyer
  /// à l'écran de connexion tant qu'il en reste un autre.
  Future<ServerAccount?> forget(String id, {bool persist = true}) async {
    if (accountById(id) == null) return active;
    _accounts = [
      for (final account in _accounts)
        if (account.id != id) account,
    ];
    await _deleteToken(id);
    await clearProfile(id);
    if (_activeId == id) {
      _activeId = _accounts.isEmpty ? null : _accounts.first.id;
    }
    if (persist) {
      await _persist();
      notifyListeners();
    }
    return active;
  }

  // ==================== JETONS ====================
  //
  // Écrits dans les préférences **et** dans le coffre : le coffre est le bon
  // endroit, mais il échoue sur certaines plateformes, et une session perdue à
  // chaque lancement est pire qu'un jeton en clair dans le bac à sable de l'app.
  // C'est le compromis que faisait déjà la version mono-serveur.

  Future<String?> tokenFor(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final fromPrefs = prefs.getString('$_tokenPrefix$id');
    if (fromPrefs != null && fromPrefs.isNotEmpty) return fromPrefs;
    try {
      final fromSecure = await _secureStorage.read(key: '$_tokenPrefix$id');
      if (fromSecure != null && fromSecure.isNotEmpty) {
        await prefs.setString('$_tokenPrefix$id', fromSecure);
        return fromSecure;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _writeToken(String id, String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_tokenPrefix$id', token);
    try {
      await _secureStorage.write(key: '$_tokenPrefix$id', value: token);
    } catch (_) {}
  }

  Future<void> _deleteToken(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_tokenPrefix$id');
    try {
      await _secureStorage.delete(key: '$_tokenPrefix$id');
    } catch (_) {}
  }

  // ==================== PROFILS EN CACHE ====================
  //
  // Un profil par compte, pour que la session hors ligne rouvre l'identité du
  // serveur actif et pas celle du dernier auquel on s'est connecté.

  Future<void> writeProfile(String id, String encoded) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_profilePrefix$id', encoded);
  }

  Future<String?> readProfile(String id) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_profilePrefix$id');
  }

  Future<void> clearProfile(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_profilePrefix$id');
  }

  // ==================== DEMANDES EN ATTENTE ====================

  Future<void> addPendingRequest(PendingAccessRequest request) async {
    _pendingRequests = [
      for (final other in _pendingRequests)
        if (!(other.url == request.url && other.username == request.username))
          other,
      request,
    ];
    await _persist();
    notifyListeners();
  }

  Future<void> dropPendingRequest(String requestCode) async {
    final before = _pendingRequests.length;
    _pendingRequests = [
      for (final request in _pendingRequests)
        if (request.requestCode != requestCode) request,
    ];
    if (_pendingRequests.length == before) return;
    await _persist();
    notifyListeners();
  }

  Future<void> dropPendingRequestFor(String url, String username,
      {bool persist = true}) async {
    final normalized = ServerAccount.normalizeUrl(url);
    final before = _pendingRequests.length;
    _pendingRequests = [
      for (final request in _pendingRequests)
        if (!(request.url == normalized && request.username == username))
          request,
    ];
    if (_pendingRequests.length == before) return;
    if (persist) {
      await _persist();
      notifyListeners();
    }
  }

  /// Point d'entrée des tests : repart d'un registre vide en mémoire.
  @visibleForTesting
  void resetForTesting() {
    _accounts = const [];
    _pendingRequests = const [];
    _activeId = null;
    _loaded = false;
  }
}
