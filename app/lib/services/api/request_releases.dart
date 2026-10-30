part of '../api_client.dart';

/// La recherche interactive des demandes (ADR-0098) : les releases que les
/// indexeurs offrent pour une saison ou un épisode, lues chez MediaHub à
/// travers le serveur, et l'envoi de l'une d'elles à Radarr/Sonarr.
mixin _RequestReleaseEndpoints {
  Dio get _dio;

  /// Les releases de la cible. Lève l'erreur du serveur : 403 sans le droit,
  /// 501 chez un compagnon qui n'a pas la recherche, 502 quand MediaHub ne
  /// répond pas à temps (Prowlarr interroge tous les indexeurs).
  Future<List<RequestRelease>> getRequestReleases(
    RequestReleaseTarget target,
  ) async {
    final response = await _dio.get('/api/requests/releases',
        queryParameters: target.toQuery());
    final raw =
        (response.data as Map)['releases'] as List<dynamic>? ?? const [];
    return raw
        .map((e) => RequestRelease.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Envoie [release] au téléchargement. Lève l'erreur de MediaHub quand
  /// Radarr ou Sonarr la refuse, que l'écran affiche.
  Future<void> grabRequestRelease(
    RequestReleaseTarget target,
    RequestRelease release,
  ) async {
    await _dio.post('/api/requests/releases/grab',
        data: release.toGrabJson(target));
  }
}
