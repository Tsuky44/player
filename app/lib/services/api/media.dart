part of '../api_client.dart';

/// Médiathèque : accueil, fiches, saisons, progression, épisode suivant,
/// demandes.
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _MediaEndpoints {
  Dio get _dio;
  String get baseUrl;
  String? get accountId;
  MediaFailover get mediaFailover;
  ConditionalGetCache get _libraryLists;

  // ==================== MEDIA API ====================

  /// Client apps (APK / DMG / EXE) embedded in the server image. Unauthenticated
  /// server-side, so this also works from the login screen.
  Future<List<AppDownload>> getAppDownloads() async {
    final response = await _dio.get("/api/downloads");
    return _parseDownloads(response.data as Map<String, dynamic>);
  }

  /// Absolute URL for an artifact, ready to hand to the browser or the shell.
  String getAppDownloadUrl(AppDownload download) {
    return "$baseUrl${download.url}";
  }

  /// Fetches an artifact to [savePath] for the in-app updater.
  ///
  /// On its own Dio on purpose: the shared client pins a 30 s receive timeout
  /// that a 150 MB installer trips on any slow link, and /api/downloads is
  /// unauthenticated so none of the interceptor's work is needed here.
  Future<void> downloadAppArtifact(
    AppDownload download,
    String savePath, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
    ));
    try {
      await dio.download(
        getAppDownloadUrl(download),
        savePath,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
      );
    } finally {
      dio.close();
    }
  }

  /// Replaces the installer of one platform (admin only). The platform is
  /// deduced server-side from the extension, so [filename] must keep it.
  ///
  /// Either [path] (desktop/mobile: streamed from disk) or [bytes] (web, where
  /// there is no file path) must be given. [onProgress] receives sent/total,
  /// total being -1 while the size is unknown.
  ///
  /// Returns the refreshed artifact list.
  Future<List<AppDownload>> uploadAppDownload({
    required String filename,
    String? path,
    List<int>? bytes,
    String? version,
    void Function(int sent, int total)? onProgress,
  }) async {
    final formData = FormData.fromMap({
      if (version != null && version.isNotEmpty) "version": version,
      "file": path != null
          ? await MultipartFile.fromFile(path, filename: filename)
          : MultipartFile.fromBytes(bytes ?? const [], filename: filename),
    });

    final response = await _dio.post(
      "/api/downloads",
      data: formData,
      onSendProgress: onProgress,
      // A 150 MB installer over a home connection outlives the default
      // timeouts, and the server answers only once the file is on disk.
      options: Options(
        sendTimeout: const Duration(minutes: 30),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    return _parseDownloads(response.data as Map<String, dynamic>);
  }

  /// Removes one published installer (admin only). Returns the refreshed list.
  Future<List<AppDownload>> deleteAppDownload(AppDownload download) async {
    final response = await _dio.delete("/api/downloads/${download.file}");
    return _parseDownloads(response.data as Map<String, dynamic>);
  }

  List<AppDownload> _parseDownloads(Map<String, dynamic> data) {
    return (data['artifacts'] as List<dynamic>? ?? const [])
        .map((e) => AppDownload.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<HomeResponse> getHome() async {
    final id = accountId;
    if (id != null) unawaited(mediaFailover.refreshIdentities(id));
    final response = await _dio.get("/api/home");
    return HomeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<HomeMediaItem>> getMovies() async {
    final data =
        await _libraryLists.get(_dio, "/api/movies", scope: accountId ?? '');
    return (data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Media>> getShows() async {
    final data =
        await _libraryLists.get(_dio, "/api/shows", scope: accountId ?? '');
    return (data as List<dynamic>)
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Media>> getShowSeasons(int showId) async {
    final response = await _dio.get("/api/shows/$showId/seasons");
    return (response.data as List<dynamic>)
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Les épisodes d'une saison présente sur le serveur.
  ///
  /// Avec [includeMissing], le serveur y ajoute ceux que TMDB annonce et qu'il
  /// n'a pas (à venir ou absents), marqués indisponibles : c'est la liste de
  /// la fiche. Le lecteur et les téléchargements ne veulent que ce qui se lit.
  Future<List<HomeMediaItem>> getSeasonEpisodes(
    int seasonId, {
    bool includeMissing = false,
  }) async {
    final response = await _dio.get(
      "/api/seasons/$seasonId/episodes",
      queryParameters: includeMissing ? const {'missing': 1} : null,
    );
    return (response.data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HomeMediaItem>> getShowSeasonEpisodes(
      int showId, int seasonNumber) async {
    final response =
        await _dio.get("/api/shows/$showId/seasons/$seasonNumber/episodes");
    return (response.data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ShowResumeResponse> getShowResumeEpisode(int showId) async {
    final response = await _dio.get("/api/shows/$showId/resume");
    return ShowResumeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  // ==================== PROGRESSION HEARTBEAT ====================

  Future<Map<String, dynamic>> getProgress(int mediaId) async {
    final response = await _dio.get("/api/progress", queryParameters: {
      "media_id": mediaId,
    });
    return response.data as Map<String, dynamic>;
  }

  /// [clientUpdatedAt] date une lecture qui a eu lieu avant l'envoi — le rejeu
  /// d'un visionnage hors ligne. Le serveur s'en sert pour ne pas écraser une
  /// progression plus récente venue d'un autre appareil ; un battement de coeur
  /// normal l'omet et vaut « maintenant ».
  Future<bool> sendProgress({
    required int mediaId,
    required int currentPositionSeconds,
    required int duration,
    required bool isFinished,
    DateTime? clientUpdatedAt,
  }) async {
    final response = await _dio.post("/api/progress", data: {
      "media_id": mediaId,
      "current_position_seconds": currentPositionSeconds,
      "duration": duration,
      "is_finished": isFinished,
      if (clientUpdatedAt != null)
        "client_updated_at": clientUpdatedAt.toUtc().toIso8601String(),
    });

    return response.data["is_finished"] as bool? ?? isFinished;
  }

  // ==================== EPISODE NAVIGATION ====================

  Future<NextEpisodeResponse> getNextEpisode(int episodeId) async {
    final response = await _dio.get("/api/episodes/$episodeId/next");
    return NextEpisodeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<EpisodeTimestamps> getEpisodeTimestamps(int episodeId) async {
    final response = await _dio.get("/api/episodes/$episodeId/timestamps");
    return EpisodeTimestamps.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<VideoChapter>> getEpisodeChapters(int episodeId) async {
    final response = await _dio.get("/api/episodes/$episodeId/chapters");
    final data = response.data["chapters"] as List? ?? [];
    return data
        .map((json) => VideoChapter.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Fetches rich catalog details (cast, genres, rating, backdrop,
  /// crew…) for a movie or show, merging local library data with live TMDB.
  /// La fiche sous sa forme brute, telle que le téléchargement hors ligne la
  /// range sur le disque. Voir [getMediaTracksJson] pour le même raisonnement.
  Future<Map<String, dynamic>> getMediaDetailsJson(int mediaId) async {
    final response = await _dio.get("/api/media/$mediaId/details");
    return response.data as Map<String, dynamic>;
  }

  Future<MediaDetails> getMediaDetails(int mediaId) async {
    return MediaDetails.fromJson(await getMediaDetailsJson(mediaId));
  }

  /// Fetches an actor/crew profile with filmography (TMDB person id).
  Future<PersonDetails> getPersonDetails(int personTmdbId) async {
    final response = await _dio.get("/api/person/$personTmdbId");
    return PersonDetails.fromJson(response.data as Map<String, dynamic>);
  }

  /// Fetches a movie saga/collection with all its films (TMDB collection id).
  Future<CollectionDetails> getCollectionDetails(int collectionTmdbId) async {
    final response = await _dio.get("/api/collection/$collectionTmdbId");
    return CollectionDetails.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MediaTracks> getMediaTracks(int mediaId) async {
    return MediaTracks.fromJson(await getMediaTracksJson(mediaId));
  }

  /// Charge la liste des pistes sous sa forme brute.
  ///
  /// Le téléchargement hors ligne met cette réponse de côté telle quelle et la
  /// reparse sans serveur : la garder en JSON évite d'avoir à sérialiser
  /// [MediaTracks] en sens inverse, et la copie locale reste lisible par une
  /// version plus riche du modèle.
  Future<Map<String, dynamic>> getMediaTracksJson(int mediaId) async {
    final response = await _dio.get("/api/media/$mediaId/tracks");
    return response.data as Map<String, dynamic>;
  }

  Future<RequestCatalogPage> getRequestCatalog({
    required int page,
    required String type,
    String? query,
    RequestCatalogFilters filters = RequestCatalogFilters.defaults,
  }) async {
    final response = await _dio.get('/api/requests/catalog', queryParameters: {
      'page': page,
      'type': type,
      if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
      if (filters.hasDiscoverParams) ...filters.toQueryParams(),
    });
    return RequestCatalogPage.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<RequestGenre>> getRequestFilterGenres(String type) async {
    final response =
        await _dio.get('/api/requests/filter-options', queryParameters: {
      'type': type,
    });
    final genres = response.data['genres'] as List<dynamic>? ?? const [];
    return genres
        .map((e) => RequestGenre.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<RequestWatchProvider>> getRequestWatchProviders({
    required String type,
    required String region,
  }) async {
    final response =
        await _dio.get('/api/requests/watch-providers', queryParameters: {
      'type': type,
      'region': region,
    });
    final providers = response.data['providers'] as List<dynamic>? ?? const [];
    return providers
        .map((e) => RequestWatchProvider.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<RequestMediaDetails> getRequestMediaDetails(
      int tmdbId, RequestMediaType type) async {
    final response = await _dio.get(
      '/api/requests/media/$tmdbId',
      queryParameters: {'type': type.name},
    );
    return RequestMediaDetails.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<RequestEpisode>> getRequestSeasonEpisodes(
      int tmdbId, int seasonNumber) async {
    final response = await _dio.get(
      '/api/requests/media/$tmdbId/seasons/$seasonNumber/episodes',
    );
    final episodes = response.data['episodes'] as List<dynamic>? ?? const [];
    return episodes
        .map((item) => RequestEpisode.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> requestMedia(
    RequestMediaItem media, {
    List<int>? seasons,
  }) {
    return requestTmdbMedia(
      tmdbId: media.id,
      mediaType: media.mediaType.name,
      title: media.title,
      posterPath: media.posterPath,
      seasons: seasons,
    );
  }

  /// Sends a MediaHub request from anywhere a TMDB id is known — the requests
  /// catalog, the library show page, or the player's end-of-season card.
  Future<void> requestTmdbMedia({
    required int tmdbId,
    required String mediaType,
    required String title,
    String? posterPath,
    List<int>? seasons,
  }) async {
    await _dio.post('/api/requests', data: {
      'tmdbId': tmdbId,
      'mediaType': mediaType,
      'title': title,
      'posterPath': posterPath,
      if (seasons != null && seasons.isNotEmpty) 'seasons': seasons,
    });
  }
}
