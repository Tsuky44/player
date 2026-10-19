part of '../api_client.dart';

/// Le choix de l'affiche d'un film ou d'une série parmi celles de TMDB et de
/// Fanart.tv (ADR-0068). Le serveur réserve ces routes à `manage_library`.
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _ArtworkEndpoints {
  Dio get _dio;

  /// Les affiches proposées pour [mediaId], ou null quand le serveur est trop
  /// ancien pour en proposer : l'app le dit au lieu de lire un 404.
  Future<RemotePosters?> getRemotePosters(int mediaId) async {
    final ping = await _dio.get('/api/ping');
    final info = ServerCapabilities.tryParse(ping.data);
    if (info == null || !info.supports(ServerCapabilities.posterPicker)) {
      return null;
    }
    final response = await _dio.get(
      '/api/media/$mediaId/images/posters',
      // Le serveur attend TMDB et Fanart.tv, jusqu'à 15 s.
      options: Options(receiveTimeout: const Duration(seconds: 20)),
    );
    return RemotePosters.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  /// Enregistre [posterUrl], une des adresses de [getRemotePosters], et rend
  /// la fiche à jour.
  Future<Media> setMediaPoster(int mediaId, String posterUrl) async {
    final response = await _dio.put(
      '/api/media/$mediaId/poster',
      data: {'url': posterUrl},
    );
    return Media.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  /// Rend à la fiche l'affiche que TMDB donne par défaut.
  Future<Media> resetMediaPoster(int mediaId) async {
    final response = await _dio.delete('/api/media/$mediaId/poster');
    return Media.fromJson(Map<String, dynamic>.from(response.data as Map));
  }
}
