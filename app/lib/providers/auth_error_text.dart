import 'package:dio/dio.dart';

import '../l10n/tr.dart';

/// La phrase affichée quand une connexion ou une inscription échoue : celle
/// du serveur quand il en écrit une, sinon ce que l'erreur réseau laisse
/// deviner.
String authErrorText(Object error) {
  if (error is DioException) {
    if (error.response != null && error.response?.data is Map) {
      final data = error.response?.data as Map;
      if (data.containsKey("error")) {
        return data["error"].toString();
      }
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return tr('Connexion au serveur expirée (Timeout).');
    }
    if (error.type == DioExceptionType.connectionError) {
      return tr('Connexion au serveur impossible. Vérifiez l\'adresse IP et que '
          'le serveur est allumé.');
    }
  }

  final errorStr = error.toString();
  if (errorStr.contains("SocketException") ||
      errorStr.contains("Failed host lookup")) {
    return tr('Adresse serveur introuvable ou réseau inaccessible.');
  }
  return tr('Une erreur est survenue : {0}', [errorStr]);
}
