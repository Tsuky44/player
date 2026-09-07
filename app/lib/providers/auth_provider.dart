import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/models.dart';
import '../models/server_account.dart';
import '../services/api_client.dart';
import '../utils/app_platform.dart';

class AuthProvider extends ChangeNotifier {
  final ApiClient apiClient;

  User? _currentUser;
  bool _isAuthenticated = false;
  bool _isInitializing = true;
  bool _isLoading = false;
  String? _errorMessage;

  /// La session ouverte l'a été sur un profil en cache, faute d'avoir pu
  /// joindre le serveur. Tout ce qui vient du réseau est indisponible ; ce qui
  /// a été téléchargé, non.
  bool _isOfflineSession = false;

  AuthProvider(this.apiClient) {
    // Le carnet de serveurs se modifie aussi sans passer par ici — un renommage
    // depuis l'écran des serveurs, par exemple. Le relayer évite que le menu de
    // compte affiche l'ancien nom jusqu'au prochain événement.
    apiClient.servers.addListener(notifyListeners);
    tryAutoLogin();
  }

  @override
  void dispose() {
    apiClient.servers.removeListener(notifyListeners);
    super.dispose();
  }

  User? get currentUser => _currentUser;

  /// Rights of the signed-in account. An unknown user gets nothing, so a screen
  /// that renders before the profile lands stays closed rather than open.
  Permissions get permissions => _currentUser?.permissions ?? const Permissions();
  bool get isOwner => _currentUser?.isOwner ?? false;
  bool get isAuthenticated => _isAuthenticated;

  /// Vrai quand l'identité affichée vient du disque et non du serveur.
  bool get isOfflineSession => _isOfflineSession;
  bool get isInitializing => _isInitializing;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  // Attempt connection with saved session token
  Future<void> tryAutoLogin() async {
    _isInitializing = true;
    notifyListeners();

    if (!apiClient.hasSavedToken) {
      _isInitializing = false;
      notifyListeners();
      return;
    }

    try {
      _currentUser = await apiClient.getMe();
      await apiClient.saveLastUsername(_currentUser!.username);
      await apiClient.cacheProfile(_currentUser!);
      _isAuthenticated = true;
      _isOfflineSession = false;
      _errorMessage = null;
    } on DioException catch (e) {
      // Un 401 est un verdict : la session n'existe plus, on nettoie et on
      // renvoie vers l'écran de connexion. Une absence de réponse n'est un
      // verdict sur rien — c'est le cas hors ligne, et il se rattrape.
      if (e.response?.statusCode == 401) {
        _currentUser = null;
        _isAuthenticated = false;
        _isOfflineSession = false;
        await apiClient.clearAuth();
      } else if (!await _openOfflineSession()) {
        _currentUser = null;
        _isAuthenticated = false;
      }
    } catch (_) {
      if (!await _openOfflineSession()) {
        _currentUser = null;
        _isAuthenticated = false;
      }
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  /// Ouvre une session sur le profil mis de côté au dernier passage en ligne.
  ///
  /// Le jeton est toujours là — il n'a pas été invalidé, juste impossible à
  /// présenter — donc la première requête qui aboutira après la reconnexion
  /// repartira normalement. Renvoie false quand aucun profil n'a été gardé :
  /// il n'y a alors rien à ouvrir, et l'écran de connexion est la bonne réponse.
  Future<bool> _openOfflineSession() async {
    final cached = await apiClient.readCachedProfile();
    if (cached == null) return false;
    _currentUser = cached;
    _isAuthenticated = true;
    _isOfflineSession = true;
    _errorMessage = null;
    return true;
  }

  /// Le serveur répond de nouveau : on retente une vraie authentification.
  ///
  /// Sans effet quand la session en cours est déjà en ligne, pour que le
  /// sondage de connectivité puisse appeler sans condition.
  Future<void> reconnect() async {
    if (!_isOfflineSession) return;
    try {
      _currentUser = await apiClient.getMe();
      await apiClient.cacheProfile(_currentUser!);
      _isAuthenticated = true;
      _isOfflineSession = false;
      notifyListeners();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await apiClient.clearAuth();
        _currentUser = null;
        _isAuthenticated = false;
        _isOfflineSession = false;
        notifyListeners();
      }
    } catch (_) {}
  }

  // Connect user
  Future<bool> login(String serverUrl, String username, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // 1. Establish the connection URL in client (registers base url)
      await apiClient.setConnection(serverUrl);
      
      // 2. Try login (will save token internally inside ApiClient)
      _currentUser = await apiClient.login(username, password);
      await apiClient.cacheProfile(_currentUser!);
      _isAuthenticated = true;
      _isOfflineSession = false;
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _currentUser = null;
      _isAuthenticated = false;
      _errorMessage = _parseError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Register user. Only succeeds on a pristine server (that account becomes the
  // owner) or with a valid invitation token.
  Future<bool> register(
    String serverUrl,
    String username,
    String password, {
    String? inviteToken,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await apiClient.setConnection(serverUrl);
      await apiClient.register(username, password, inviteToken: inviteToken);

      _isLoading = false;
      _errorMessage = null;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _parseError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Signs in with a session someone else already approved.
  ///
  /// The television path: no password is typed here and none is held, because
  /// the credential never existed on this device — the phone's approval minted
  /// the session directly on the server.
  Future<void> adoptPairedSession({
    required String token,
    required User user,
  }) async {
    await apiClient.adoptSession(
      token,
      username: user.username,
      userId: user.id,
    );

    await apiClient.cacheProfile(user);
    _currentUser = user;
    _isAuthenticated = true;
    _isOfflineSession = false;
    _errorMessage = null;
    _isLoading = false;
    notifyListeners();
  }

  /// Re-reads the profile from the server. Called after a 403, so a user whose
  /// rights changed under them sees the UI catch up without signing out.
  Future<void> refreshProfile() async {
    if (!_isAuthenticated) return;
    try {
      _currentUser = await apiClient.getMe();
      notifyListeners();
    } catch (_) {
      // A failed refresh leaves the previous profile in place: the server still
      // decides on every call, so a stale view costs nothing.
    }
  }

  /// Ferme la session du serveur actif sur cet appareil.
  ///
  /// Quand un autre compte reste au carnet, on y bascule au lieu de retomber
  /// sur l'écran de connexion : se déconnecter d'un serveur n'est pas se
  /// déconnecter de l'app.
  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    await apiClient.logout();

    final next = apiClient.servers.active;
    if (next != null && await apiClient.activateAccount(next.id)) {
      _onServerChanged?.call();
      await _openSessionOnActive();
      _isLoading = false;
      notifyListeners();
      return;
    }

    _currentUser = null;
    _isAuthenticated = false;
    _isOfflineSession = false;
    _isLoading = false;

    notifyListeners();
  }

  // ==================== PLUSIEURS SERVEURS ====================
  //
  // L'app tient un carnet de comptes (un par serveur) et n'en active qu'un.
  // Basculer ne renégocie rien : le jeton de l'autre serveur est déjà là, il
  // n'avait simplement pas cours. Voir ADR-0013.

  /// Prévenu juste avant qu'une bascule prenne effet, pour que les providers
  /// vident ce qui appartenait au serveur précédent. Branché dans `main()` —
  /// [AuthProvider] n'a pas à connaître la bibliothèque ni les téléchargements.
  void Function()? _onServerChanged;

  set onServerChanged(void Function()? callback) => _onServerChanged = callback;

  List<ServerAccount> get servers => apiClient.servers.accounts;
  ServerAccount? get activeServer => apiClient.servers.active;
  bool get hasMultipleServers => apiClient.servers.hasMultipleServers;
  List<PendingAccessRequest> get pendingAccessRequests =>
      apiClient.servers.pendingRequests;

  /// Bascule sur un autre serveur du carnet.
  ///
  /// L'identité est relue au serveur d'arrivée avant d'annoncer quoi que ce
  /// soit : les droits ne sont pas les mêmes des deux côtés, et afficher ceux
  /// du serveur qu'on quitte ouvrirait des écrans sur lesquels tout finirait
  /// en 403.
  Future<bool> switchServer(String accountId) async {
    if (activeServer?.id == accountId) return true;

    _isLoading = true;
    notifyListeners();

    if (!await apiClient.activateAccount(accountId)) {
      _isLoading = false;
      _errorMessage = "Ce serveur n'est plus enregistré sur cet appareil.";
      notifyListeners();
      return false;
    }

    _onServerChanged?.call();
    final ok = await _openSessionOnActive();
    _isLoading = false;
    notifyListeners();
    return ok;
  }

  /// Ouvre la session du compte devenu actif : profil du serveur si on peut le
  /// joindre, profil en cache sinon. Le même compromis qu'au démarrage, pour la
  /// même raison — un serveur injoignable ne prouve pas qu'on n'y a plus de
  /// compte, et les téléchargements, eux, sont sur le disque.
  Future<bool> _openSessionOnActive() async {
    try {
      _currentUser = await apiClient.getMe();
      await apiClient.cacheProfile(_currentUser!);
      _isAuthenticated = true;
      _isOfflineSession = false;
      _errorMessage = null;
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // La session a été révoquée de l'autre côté : le compte reste au
        // carnet, mais il faudra retaper un mot de passe.
        await apiClient.clearAuth();
        _currentUser = null;
        _isAuthenticated = false;
        _isOfflineSession = false;
        _errorMessage = 'Session expirée sur ce serveur, reconnectez-vous.';
        return false;
      }
      return await _openOfflineSession();
    } catch (_) {
      return await _openOfflineSession();
    }
  }

  /// Retire un serveur du carnet sans passer par sa page de déconnexion.
  ///
  /// La session correspondante n'est pas fermée côté serveur : on ne peut pas
  /// la fermer sans repointer le client dessus, et un compte qu'on retire de
  /// cet appareil-ci n'a pas à faire tomber les autres.
  Future<void> forgetServer(String accountId) async {
    final wasActive = activeServer?.id == accountId;
    await apiClient.forgetAccount(accountId);
    if (!wasActive) {
      notifyListeners();
      return;
    }

    final next = apiClient.servers.active;
    if (next != null && await apiClient.activateAccount(next.id)) {
      _onServerChanged?.call();
      await _openSessionOnActive();
    } else {
      _currentUser = null;
      _isAuthenticated = false;
      _isOfflineSession = false;
    }
    notifyListeners();
  }

  /// Ajoute un serveur sur lequel on a déjà un compte.
  ///
  /// Rien à demander à personne : le mot de passe suffit. La session n'est pas
  /// activée quand une autre est déjà ouverte — le carnet s'allonge, l'écran ne
  /// bouge pas.
  Future<ServerAccount> addServerWithPassword({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final activate = !_isAuthenticated;
    final user = await apiClient.signInAt(
      serverUrl: serverUrl,
      username: username,
      password: password,
      activate: activate,
    );
    if (activate) {
      _onServerChanged?.call();
      _currentUser = user;
      _isAuthenticated = true;
      _isOfflineSession = false;
      _errorMessage = null;
      await apiClient.cacheProfile(user);
    }
    notifyListeners();
    return apiClient.servers.accountForUrl(serverUrl)!;
  }

  // ==================== DEMANDES D'ACCÈS ====================

  /// Sonne à la porte d'un serveur où l'on n'a pas de compte.
  ///
  /// La demande est notée sur l'appareil : un administrateur peut mettre des
  /// jours à répondre, et le code qui permettra de relever la session ne se
  /// retrouve nulle part ailleurs.
  Future<PendingAccessRequest> requestAccess({
    required String serverUrl,
    required String username,
    required String password,
    String? message,
  }) async {
    final url = ServerAccount.normalizeUrl(serverUrl);
    final ticket = await apiClient.requestAccess(
      serverUrl: url,
      username: username,
      password: password,
      deviceName: AppPlatform.label,
      message: message,
    );
    final pending = PendingAccessRequest(
      url: url,
      username: username,
      requestCode: ticket.requestCode,
      createdAt: DateTime.now(),
    );
    await apiClient.servers.addPendingRequest(pending);
    notifyListeners();
    return pending;
  }

  /// Demande le verdict d'une demande en attente.
  ///
  /// Une approbation entre au carnet **sans** basculer dessus quand une session
  /// est déjà ouverte ailleurs : l'utilisateur regardait peut-être un film. Sur
  /// un appareil qui n'a encore aucun compte, elle ouvre la session, parce que
  /// c'est précisément ce qu'il attendait.
  Future<AccessRequestStatus> checkAccessRequest(
    PendingAccessRequest request,
  ) async {
    final AccessRequestVerdict verdict;
    try {
      verdict = await apiClient.pollAccessRequest(
        serverUrl: request.url,
        requestCode: request.requestCode,
      );
    } catch (_) {
      // Serveur injoignable : la demande tient toujours, on redemandera.
      return AccessRequestStatus.pending;
    }

    switch (verdict.status) {
      case AccessRequestStatus.approved:
        final token = verdict.token;
        final userJson = verdict.user;
        if (token == null || userJson == null) {
          await apiClient.servers.dropPendingRequest(request.requestCode);
          return AccessRequestStatus.expired;
        }
        final user = User.fromJson(userJson);
        final hadSession = _isAuthenticated;
        await apiClient.rememberSession(
          serverUrl: request.url,
          username: user.username,
          token: token,
          userId: user.id,
          activate: !hadSession,
        );
        await apiClient.servers.dropPendingRequest(request.requestCode);
        if (!hadSession) {
          _onServerChanged?.call();
          _currentUser = user;
          _isAuthenticated = true;
          _isOfflineSession = false;
          _errorMessage = null;
          await apiClient.cacheProfile(user);
        }
        notifyListeners();
        return AccessRequestStatus.approved;

      case AccessRequestStatus.denied:
      case AccessRequestStatus.expired:
        await apiClient.servers.dropPendingRequest(request.requestCode);
        notifyListeners();
        return verdict.status;

      case AccessRequestStatus.pending:
        return AccessRequestStatus.pending;
    }
  }

  /// Repasse sur toutes les demandes en attente. Appelé au démarrage et au
  /// retour du réseau : c'est ce qui fait qu'une approbation arrivée pendant la
  /// nuit est déjà là au réveil de l'app.
  Future<void> refreshAccessRequests() async {
    for (final request in List.of(pendingAccessRequests)) {
      await checkAccessRequest(request);
    }
  }

  Future<void> abandonAccessRequest(PendingAccessRequest request) async {
    await apiClient.servers.dropPendingRequest(request.requestCode);
    notifyListeners();
  }

  String _parseError(dynamic error) {
    if (error is DioException) {
      if (error.response != null && error.response?.data is Map) {
        final data = error.response?.data as Map;
        if (data.containsKey("error")) {
          return data["error"].toString();
        }
      }
      if (error.type == DioExceptionType.connectionTimeout || error.type == DioExceptionType.receiveTimeout) {
        return "Connexion au serveur expirée (Timeout).";
      }
      if (error.type == DioExceptionType.connectionError) {
        return "Connexion au serveur impossible. Vérifiez l'adresse IP et que le serveur est allumé.";
      }
    }
    
    final errorStr = error.toString();
    if (errorStr.contains("SocketException") || errorStr.contains("Failed host lookup")) {
      return "Adresse serveur introuvable ou réseau inaccessible.";
    }
    return "Une erreur est survenue : $errorStr";
  }
}
