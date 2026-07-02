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

  AuthProvider(this.apiClient) {
    tryAutoLogin();
  }

  User? get currentUser => _currentUser;
  bool get isAuthenticated => _isAuthenticated;
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
      _isAuthenticated = true;
      _errorMessage = null;
    } on DioException catch (e) {
      _currentUser = null;
      _isAuthenticated = false;
      if (e.response?.statusCode == 401) {
        await apiClient.clearAuth();
      }
    } catch (_) {
      _currentUser = null;
      _isAuthenticated = false;
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
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
      _isAuthenticated = true;
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

  // Register user
  Future<bool> register(String serverUrl, String username, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await apiClient.setConnection(serverUrl);
      await apiClient.register(username, password);
      
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

  // Disconnect user
  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();
    
    await apiClient.logout();
    _currentUser = null;
    _isAuthenticated = false;
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
