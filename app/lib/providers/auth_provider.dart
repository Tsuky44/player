import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/models.dart';
import '../models/server_account.dart';
import '../services/api_client.dart';
import '../utils/app_platform.dart';

/// Ce que donne une tentative d'ouverture de session sur le compte actif.
///
/// Quatre issues et pas deux, parce que l'app n'en tire pas la même
/// conclusion : un refus renvoie à l'écran de connexion, un serveur muet peut
/// valoir une bascule, et un serveur qui répond de travers ne prouve pas
/// qu'il est éteint.
enum _SessionOutcome {
  /// Le profil est arrivé : la session est ouverte pour de bon.
  opened,

  /// 401 : la session n'existe plus de l'autre côté.
  unauthorized,

  /// Aucune réponse : le serveur est injoignable d'ici.
  unreachable,

  /// Une réponse, mais inexploitable — un 500, un corps illisible.
  faulted,
}

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

  /// Le serveur principal n'a pas répondu au démarrage et il reste d'autres
  /// comptes au carnet : l'app attend qu'on lui dise où aller plutôt que de
  /// choisir à la place de l'utilisateur.
  ServerAccount? _unreachablePrimary;

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

    // Le serveur principal passe avant celui qu'on regardait la dernière fois :
    // c'est tout ce qu'on lui demande d'être.
    await _applyPrimaryServer();

    if (!apiClient.hasSavedToken) {
      _isInitializing = false;
      notifyListeners();
      return;
    }

    // Un 401 est un verdict : la session n'existe plus, on nettoie et on
    // renvoie vers l'écran de connexion. Une absence de réponse n'est un
    // verdict sur rien — c'est le cas hors ligne, et il se rattrape.
    switch (await _probeSessionOnActive(announceExpiry: false)) {
      case _SessionOutcome.opened:
        await apiClient.saveLastUsername(_currentUser!.username);
      case _SessionOutcome.unauthorized:
        break;
      case _SessionOutcome.unreachable:
        // Le principal est muet : on demande où aller tant qu'il y a un
        // ailleurs. Sinon la session hors ligne reste la meilleure réponse.
        if (!_askWhereToGo() && !await _openOfflineSession()) {
          _currentUser = null;
          _isAuthenticated = false;
        }
      case _SessionOutcome.faulted:
        if (!await _openOfflineSession()) {
          _currentUser = null;
          _isAuthenticated = false;
        }
    }

    _isInitializing = false;
    notifyListeners();
  }

  /// Remet l'app sur le serveur principal, s'il y en a un de désigné.
  ///
  /// Sans sonder quoi que ce soit : c'est la requête de profil qui suit qui
  /// dira s'il répond, et un aller-retour de plus devant l'écran de démarrage
  /// se paie sur tous les lancements pour renseigner le cas rare.
  Future<void> _applyPrimaryServer() async {
    final registry = apiClient.servers;
    await registry.load();
    final primary = registry.primary;
    if (primary == null || registry.active?.id == primary.id) return;
    if (await apiClient.activateAccount(primary.id)) _onServerChanged?.call();
  }

  /// Retient qu'il faut poser la question, et rend vrai quand c'est le cas.
  ///
  /// Uniquement quand le serveur muet est le principal — sans principal,
  /// personne n'a demandé à démarrer ici plutôt qu'ailleurs — et qu'il reste
  /// au moins un autre compte : une liste d'un seul serveur ne propose rien.
  bool _askWhereToGo() {
    final registry = apiClient.servers;
    final primary = registry.primary;
    if (primary == null ||
        registry.active?.id != primary.id ||
        registry.accounts.length < 2) {
      return false;
    }
    _unreachablePrimary = primary;
    _currentUser = null;
    _isAuthenticated = false;
    _isOfflineSession = false;
    _errorMessage = null;
    return true;
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
    // La question posée au démarrage se referme d'elle-même quand le serveur
    // principal se réveille : personne n'a à choisir un pis-aller parce qu'un
    // NAS a mis trente secondes de plus que l'app à démarrer.
    if (needsServerChoice) {
      await retryPrimaryServer();
      return;
    }
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

  // ==================== SERVEUR PRINCIPAL ====================
  //
  // Un serveur peut être désigné comme celui du démarrage : l'app s'y remet à
  // chaque lancement, quel que soit celui qu'on regardait la fois d'avant.
  // Quand il ne répond pas et qu'il reste d'autres comptes, elle demande où
  // aller plutôt que de se rabattre en silence sur le cache — se retrouver
  // hors ligne sans l'avoir demandé, avec un autre serveur allumé à côté, est
  // exactement ce que ce réglage sert à éviter.

  /// Le serveur de démarrage, s'il en existe un.
  ServerAccount? get primaryServer => apiClient.servers.primary;

  bool isPrimaryServer(String accountId) =>
      apiClient.servers.isPrimary(accountId);

  /// Désigne le serveur de démarrage, ou le libère avec `null`.
  Future<void> setPrimaryServer(String? accountId) async {
    await apiClient.servers.setPrimary(accountId);
    notifyListeners();
  }

  /// Le principal auquel on n'a pas pu se connecter au lancement. Non nul tant
  /// que l'utilisateur n'a pas tranché.
  ServerAccount? get unreachablePrimary => _unreachablePrimary;

  bool get needsServerChoice => _unreachablePrimary != null;

  /// Redemande au serveur principal, pour le cas où il vient de se réveiller.
  Future<bool> retryPrimaryServer() async {
    final primary = _unreachablePrimary;
    if (primary == null) return _isAuthenticated;

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    if (apiClient.servers.active?.id != primary.id) {
      await apiClient.activateAccount(primary.id);
      _onServerChanged?.call();
    }
    final outcome = await _probeSessionOnActive();
    // Toujours muet : la question reste posée. Répondu, même mal : elle n'a
    // plus lieu d'être, et l'app repart sur ce que le serveur a dit.
    if (outcome != _SessionOutcome.unreachable) _unreachablePrimary = null;
    if (outcome == _SessionOutcome.faulted) await _openOfflineSession();

    _isLoading = false;
    notifyListeners();
    return outcome == _SessionOutcome.opened;
  }

  /// Reste sur le principal sans lui : la session s'ouvre sur le profil mis de
  /// côté au dernier passage en ligne, et les téléchargements sont sur le
  /// disque. Faux quand il n'y a aucun profil à rouvrir — l'écran de connexion
  /// est alors la seule réponse honnête.
  Future<bool> continueOfflineOnPrimary() async {
    _unreachablePrimary = null;
    final opened = await _openOfflineSession();
    if (!opened) {
      _currentUser = null;
      _isAuthenticated = false;
    }
    notifyListeners();
    return opened;
  }

  /// Bascule sur un autre serveur du carnet.
  ///
  /// L'identité est relue au serveur d'arrivée avant d'annoncer quoi que ce
  /// soit : les droits ne sont pas les mêmes des deux côtés, et afficher ceux
  /// du serveur qu'on quitte ouvrirait des écrans sur lesquels tout finirait
  /// en 403.
  Future<bool> switchServer(String accountId, {bool synchronize = true}) async {
    if (activeServer?.id == accountId) return true;

    _isLoading = true;
    notifyListeners();

    if (!await apiClient.activateAccount(accountId, synchronize: synchronize)) {
      _isLoading = false;
      _errorMessage = "Ce serveur n'est plus enregistré sur cet appareil.";
      notifyListeners();
      return false;
    }

    _unreachablePrimary = null;
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
    final outcome = await _probeSessionOnActive();
    switch (outcome) {
      case _SessionOutcome.opened:
        return true;
      case _SessionOutcome.unauthorized:
        return false;
      case _SessionOutcome.unreachable:
      case _SessionOutcome.faulted:
        return await _openOfflineSession();
    }
  }

  /// Demande son profil au serveur du compte actif et dit ce qui s'est passé,
  /// sans rien décider : c'est l'appelant qui sait s'il peut se rabattre sur
  /// le cache, proposer un autre serveur ou renvoyer à l'écran de connexion.
  ///
  /// [announceExpiry] laisse le message de session expirée à l'écran. Au
  /// démarrage il n'a rien à y faire — personne n'a rien tenté.
  Future<_SessionOutcome> _probeSessionOnActive({
    bool announceExpiry = true,
  }) async {
    try {
      _currentUser = await apiClient.getMe();
      await apiClient.cacheProfile(_currentUser!);
      _isAuthenticated = true;
      _isOfflineSession = false;
      _errorMessage = null;
      return _SessionOutcome.opened;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // La session a été révoquée de l'autre côté : le compte reste au
        // carnet, mais il faudra retaper un mot de passe.
        await apiClient.clearAuth();
        _currentUser = null;
        _isAuthenticated = false;
        _isOfflineSession = false;
        if (announceExpiry) {
          _errorMessage = 'Session expirée sur ce serveur, reconnectez-vous.';
        }
        return _SessionOutcome.unauthorized;
      }
      // Une réponse, même mauvaise, prouve qu'il y a quelqu'un en face : ce
      // n'est pas un serveur éteint, et ça ne vaut pas une bascule.
      return e.response == null
          ? _SessionOutcome.unreachable
          : _SessionOutcome.faulted;
    } catch (_) {
      return _SessionOutcome.faulted;
    }
  }

  /// Retire un serveur du carnet sans passer par sa page de déconnexion.
  ///
  /// La session correspondante n'est pas fermée côté serveur : on ne peut pas
  /// la fermer sans repointer le client dessus, et un compte qu'on retire de
  /// cet appareil-ci n'a pas à faire tomber les autres.
  Future<void> forgetServer(String accountId) async {
    final wasActive = activeServer?.id == accountId;
    if (_unreachablePrimary?.id == accountId) _unreachablePrimary = null;
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
