part of '../api_client.dart';

/// Liens de partage publics (ADR-0037). Voir server/handlers/media_shares.go.
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes restent des méthodes d'instance, surchargeables par les doublures
/// de test.
mixin _MediaShareEndpoints {
  Dio get _dio;
  String get baseUrl;

  Future<MediaShare> createMediaShare({
    required int mediaId,
    String password = '',
    required bool singleUse,
    required ShareLifetime lifetime,
  }) async {
    final response = await _dio.post('/api/shares', data: {
      'media_id': mediaId,
      'password': password,
      'single_use': singleUse,
      'expires_in_hours': lifetime.hours,
    });
    return MediaShare.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<MediaShare>> listMediaShares() async {
    final response = await _dio.get('/api/shares');
    return (response.data as List<dynamic>? ?? const [])
        .map((e) => MediaShare.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteMediaShare(int id) async {
    await _dio.delete('/api/shares/$id');
  }

  /// L'adresse à envoyer pour [code].
  ///
  /// Composée à partir de l'adresse à laquelle ce client est connecté, comme
  /// un lien d'invitation : derrière un proxy, le serveur ne connaît pas la
  /// sienne. Le code est dans le fragment (#), que le navigateur n'envoie
  /// jamais au serveur : il ne finit dans aucun journal.
  String mediaShareLink(String code) => '$baseUrl/share#$code';
}
