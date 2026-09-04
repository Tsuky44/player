import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/models.dart';
import '../services/api_client.dart';

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
    tryAutoLogin();
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
    await apiClient.adoptSession(token);
    await apiClient.saveLastUsername(user.username);

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

  // Disconnect user
  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();
    
    await apiClient.logout();
    _currentUser = null;
    _isAuthenticated = false;
    _isOfflineSession = false;
    _isLoading = false;
    
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
