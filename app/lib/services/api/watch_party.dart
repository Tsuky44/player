part of '../api_client.dart';

/// Regarder ensemble (ADR-0029).
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _WatchPartyEndpoints {
  Dio get _dio;

  // ==================== REGARDER ENSEMBLE ====================
  //
  // Voir server/handlers/watch_party.go. Les réponses sont rendues brutes :
  // c'est [WatchPartySession] qui les date à la réception, ce dont dépend
  // toute la synchronisation.

  Future<Map<String, dynamic>> createWatchParty({
    required int mediaId,
    required double positionSeconds,
    required bool playing,
  }) async {
    final response = await _dio.post('/api/watch-parties', data: {
      'media_id': mediaId,
      'position_seconds': positionSeconds,
      'playing': playing,
    });
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> joinWatchParty(String code) async {
    final response =
        await _dio.post('/api/watch-parties/${Uri.encodeComponent(code)}/join');
    return response.data as Map<String, dynamic>;
  }

  /// Attend le prochain changement après [since] — jusqu'à une vingtaine de
  /// secondes, sous le délai de réception du client.
  Future<Map<String, dynamic>> pollWatchParty(
    String code, {
    required String memberId,
    required int since,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      '/api/watch-parties/${Uri.encodeComponent(code)}',
      queryParameters: {'member': memberId, 'since': since},
      cancelToken: cancelToken,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateWatchParty(
    String code, {
    required String memberId,
    required String action,
    bool? playing,
    double? positionSeconds,
    int? mediaId,
    bool? loading,
  }) async {
    final response = await _dio.post(
      '/api/watch-parties/${Uri.encodeComponent(code)}/state',
      data: {
        'member_id': memberId,
        'action': action,
        if (playing != null) 'playing': playing,
        if (positionSeconds != null) 'position_seconds': positionSeconds,
        if (mediaId != null) 'media_id': mediaId,
        if (loading != null) 'loading': loading,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> leaveWatchParty(String code, {required String memberId}) async {
    await _dio.post(
      '/api/watch-parties/${Uri.encodeComponent(code)}/leave',
      data: {'member_id': memberId},
    );
  }

  Future<Map<String, dynamic>> setMediaWatched(
      int mediaId, bool watched) async {
    final response = await _dio.post("/api/media/$mediaId/watched", data: {
      "watched": watched,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Marque un lot de médias — en pratique une saison entière — vu ou non vu.
  ///
  /// Renvoie, par identifiant, ce que le serveur a retenu ; les identifiants
  /// qu'il refuse (un épisode disparu, une saison) manquent simplement à
  /// l'appel. Un serveur plus ancien ne connaît pas la route de lot : on
  /// retombe alors sur les appels un par un, qui font le même travail en
  /// vingt requêtes au lieu d'une.
  Future<Map<int, Map<String, dynamic>>> setMediasWatched(
      List<int> mediaIds, bool watched) async {
    if (mediaIds.isEmpty) return {};
    try {
      final response = await _dio.post("/api/progress/watched", data: {
        "media_ids": mediaIds,
        "watched": watched,
      });
      final updated = (response.data as Map)["updated"] as List? ?? const [];
      return {
        for (final entry in updated)
          if (entry is Map && entry["media_id"] is int)
            entry["media_id"] as int: Map<String, dynamic>.from(entry),
      };
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status != 404 && status != 405) rethrow;
      final results = <int, Map<String, dynamic>>{};
      for (final mediaId in mediaIds) {
        results[mediaId] = await setMediaWatched(mediaId, watched);
      }
      return results;
    }
  }

  Future<void> hideFromContinueWatching({int? movieId, int? showId}) async {
    final data = <String, dynamic>{};
    if (movieId != null) data['movie_id'] = movieId;
    if (showId != null) data['show_id'] = showId;
    await _dio.post('/api/continue-watching/hide', data: data);
  }
}
