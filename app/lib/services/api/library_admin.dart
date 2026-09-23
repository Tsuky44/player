part of '../api_client.dart';

/// Indexation, réglages du serveur et synchronisation Emby.
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _LibraryAdminEndpoints {
  Dio get _dio;

  // ==================== INDEXER API ====================

  Future<void> triggerScan() async {
    await _dio.post("/api/indexer/scan");
  }

  Future<void> triggerMetadataBackfill() async {
    await _dio.post("/api/indexer/metadata/backfill");
  }

  Future<void> triggerRedetectAllMatches() async {
    await _dio.post("/api/indexer/metadata/redetect-all");
  }

  /// Movies and shows that remain unidentified or have incomplete artwork/text.
  /// The server rebuilds this queue from its database on every request.
  Future<List<Media>> getMediaReviewQueue() async {
    final response = await _dio.get("/api/indexer/review");
    final data = response.data as Map<String, dynamic>;
    final items = data["items"] as List? ?? const [];
    return items
        .map((e) => Media.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Fetches TMDB poster/overview for a single movie or show.
  Future<Media> enrichMediaMetadata(int mediaId) async {
    final response = await _dio.post("/api/media/$mediaId/metadata/enrich");
    return Media.fromJson(response.data as Map<String, dynamic>);
  }

  Future<Media> redetectMediaMetadata(int mediaId) async {
    final response = await _dio.post("/api/media/$mediaId/metadata/redetect");
    return Media.fromJson(response.data as Map<String, dynamic>);
  }

  /// Re-identifies a movie/show against TMDB to fix a wrong match. Provide a
  /// [title] to search for, or a [tmdbId] to force an exact entry.
  Future<Media> rematchMediaMetadata(
    int mediaId, {
    String? title,
    int? tmdbId,
  }) async {
    final response = await _dio.post(
      "/api/media/$mediaId/metadata/rematch",
      queryParameters: {
        if (title != null && title.trim().isNotEmpty) "title": title.trim(),
        if (tmdbId != null && tmdbId > 0) "tmdb_id": tmdbId,
      },
    );
    return Media.fromJson(response.data as Map<String, dynamic>);
  }

  /// Search TMDB manually for the "fix metadata" poster picker.
  Future<List<TmdbCandidate>> searchTmdb(
    String query, {
    MediaType type = MediaType.movie,
  }) async {
    final response = await _dio.get(
      "/api/tmdb/search",
      queryParameters: {
        "query": query.trim(),
        "type": type == MediaType.show ? "show" : "movie",
      },
    );
    final results = response.data["results"] as List? ?? [];
    return results
        .map((e) => TmdbCandidate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> triggerSubtitleExtract() async {
    await _dio.post("/api/indexer/subtitles/extract");
  }

  /// Extract subtitles for a single movie or episode.
  ///
  /// [force] (default) re-extracts everything — used by the manual button.
  /// When [force] is false the server only extracts if nothing is registered
  /// yet, which is the cheap "ensure" path used in the background on playback.
  Future<List<MediaSubtitleTrack>> forceMediaSubtitleExtract(
    int mediaId, {
    bool force = true,
  }) async {
    final response = await _dio.post(
      "/api/media/$mediaId/subtitles/extract",
      queryParameters: force ? null : {"force": "false"},
    );
    final subs = response.data["subtitles"] as List? ?? [];
    return subs
        .map((e) => MediaSubtitleTrack.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<IndexerStatus> getIndexerStatus() async {
    final response = await _dio.get("/api/indexer/status");
    return IndexerStatus.fromJson(response.data as Map<String, dynamic>);
  }

  Future<bool> getScanStatus() async {
    final status = await getIndexerStatus();
    return status.isScanning;
  }

  // ==================== SERVER SETTINGS ====================

  Future<ServerSettings> getServerSettings() async {
    final response = await _dio.get('/api/settings');
    return ServerSettings.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ServerSettings> updateServerSettings({
    String? mediaHubUrl,
    String? mediaHubApiKey,
    bool clearMediaHubApiKey = false,
    String? tmdbApiKey,
    bool clearTmdbApiKey = false,
    String? tmdbLanguage,
    String? moviesDir,
    String? seriesDir,
    bool? playbackLogsEnabled,
    bool? playbackStatsEnabled,
  }) async {
    final response = await _dio.put('/api/settings', data: {
      if (mediaHubUrl != null) 'mediahub_url': mediaHubUrl,
      if (mediaHubApiKey != null) 'mediahub_api_key': mediaHubApiKey,
      if (clearMediaHubApiKey) 'clear_mediahub_api_key': true,
      if (tmdbApiKey != null) 'tmdb_api_key': tmdbApiKey,
      if (clearTmdbApiKey) 'clear_tmdb_api_key': true,
      if (tmdbLanguage != null) 'tmdb_language': tmdbLanguage,
      if (moviesDir != null) 'movies_dir': moviesDir,
      if (seriesDir != null) 'series_dir': seriesDir,
      if (playbackLogsEnabled != null) 'playback_logs_enabled': playbackLogsEnabled,
      if (playbackStatsEnabled != null)
        'playback_stats_enabled': playbackStatsEnabled,
    });
    return ServerSettings.fromJson(response.data as Map<String, dynamic>);
  }

  // ==================== SYNCHRONISATION EMBY ====================

  /// Le compte Emby lié à ce compte, dont la progression est synchronisée
  /// dans les deux sens par le serveur. Voir `server/handlers/emby_sync.go`.
  Future<EmbyLinkStatus> getEmbyLink() async {
    final response = await _dio.get('/api/me/emby');
    return EmbyLinkStatus.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  /// Le mot de passe ne sert qu'à obtenir un jeton : le serveur ne le garde pas.
  Future<EmbyLinkStatus> linkEmby({
    required String url,
    required String username,
    required String password,
  }) async {
    final response = await _dio.put('/api/me/emby', data: {
      'url': url,
      'username': username,
      'password': password,
    });
    return EmbyLinkStatus.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  Future<EmbyLinkStatus> unlinkEmby() async {
    final response = await _dio.delete('/api/me/emby');
    return EmbyLinkStatus.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  /// Relit Emby et envoie ce qui a changé ici, sans attendre la tâche de fond.
  /// Renvoie le nombre de progressions reçues et envoyées.
  Future<({int pulled, int pushed})> syncEmbyNow() async {
    final response = await _dio.post(
      '/api/me/emby/sync',
      options: Options(receiveTimeout: const Duration(minutes: 5)),
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    return (
      pulled: (data['pulled'] as num?)?.toInt() ?? 0,
      pushed: (data['pushed'] as num?)?.toInt() ?? 0,
    );
  }
}
