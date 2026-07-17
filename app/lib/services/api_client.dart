import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_request.dart';
import '../models/models.dart';

/// Holds the result of starting an HLS transcoding session.
///
/// [masterUrl] is opened directly by media_kit/mpv, which fetches the child
/// playlists and segments itself (no local temp file, no playlist rewriting).
class HlsSession {
  final String sessionId;
  final String masterUrl;
  final double totalDuration; // full media duration in seconds
  final int startOffset; // seconds into the original media

  HlsSession({
    required this.sessionId,
    required this.masterUrl,
    required this.totalDuration,
    required this.startOffset,
  });

  factory HlsSession.fromJson(Map<String, dynamic> json) {
    return HlsSession(
      sessionId: json['session_id'] as String? ?? '',
      masterUrl: json['master_url'] as String? ?? '',
      totalDuration: (json['duration'] as num? ?? 0).toDouble(),
      startOffset: json['start_offset'] as int? ?? 0,
    );
  }
}

class ApiClient {
  static String get _defaultBaseUrl =>
      Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://127.0.0.1:8080';

  final Dio _dio = Dio();
  final _secureStorage = const FlutterSecureStorage();

  String? _baseUrl;
  String? _token;
  String? _savedUsername;
  bool _configLoaded = false;

  /// Loads persisted server URL and auth token. Call once at app startup.
  Future<void> initialize() async {
    await _loadConfig();
  }

  Future<String?> _readToken() async {
    final prefs = await SharedPreferences.getInstance();
    final fromPrefs = prefs.getString('auth_token');
    if (fromPrefs != null && fromPrefs.isNotEmpty) {
      return fromPrefs;
    }

    try {
      final fromSecure = await _secureStorage.read(key: 'auth_token');
      if (fromSecure != null && fromSecure.isNotEmpty) {
        await prefs.setString('auth_token', fromSecure);
        return fromSecure;
      }
    } catch (_) {}

    return null;
  }

  Future<void> _writeToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    try {
      await _secureStorage.write(key: 'auth_token', value: token);
    } catch (_) {}
  }

  Future<void> _deleteToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    try {
      await _secureStorage.delete(key: 'auth_token');
    } catch (_) {}
  }

  ApiClient() {
    _dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (!_configLoaded) {
        await _loadConfig();
      }
      options.baseUrl = _baseUrl ?? _defaultBaseUrl;

      // Inject Authorization Header
      if (_token != null) {
        options.headers["Authorization"] = "Bearer $_token";
      } else {
        final savedToken = await _readToken();
        if (savedToken != null) {
          _token = savedToken;
          options.headers["Authorization"] = "Bearer $_token";
        }
      }

      options.connectTimeout = const Duration(seconds: 10);
      options.receiveTimeout = const Duration(seconds: 30);

      return handler.next(options);
    }, onError: (DioException e, handler) {
      // Global error logging
      print(
          "API Error [${e.requestOptions.method}] ${e.requestOptions.path}: ${e.message}");
      return handler.next(e);
    }));
  }

  // Get current active base URL
  String get baseUrl => _baseUrl ?? _defaultBaseUrl;

  String? get savedUsername => _savedUsername;

  bool get hasSavedToken => _token != null && _token!.isNotEmpty;

  Future<void> saveLastUsername(String username) async {
    final value = username.trim();
    if (value.isEmpty) return;
    _savedUsername = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_username', value);
  }

  // Stream URL generator (Direct Play)
  String getStreamUrl(int mediaId) {
    return "$baseUrl/stream?media_id=$mediaId";
  }

  // HLS session destroy URL (to notify server on stop)
  String getHlsDestroyUrl(int mediaId, String sessionId) {
    return "$baseUrl/api/v1/stream/$mediaId/$sessionId";
  }

  /// URL of an external WebVTT subtitle for a given language. [start] shifts the
  /// timeline to match an HLS stream that begins at an offset; Direct Play uses 0.
  String getSubtitleUrl(int mediaId, String lang, {int start = 0}) {
    // URL ends in ".vtt" so libmpv/media_kit detects the WebVTT parser from the
    // extension; without it the external track silently fails to load.
    return "$baseUrl/api/v1/media/$mediaId/subtitles/$lang.vtt?start=$start";
  }

  /// Download the raw WebVTT text for a subtitle. Fetching it ourselves and
  /// injecting via SubtitleTrack.data() is far more reliable than asking mpv to
  /// fetch a URL while it is already busy pulling an HLS stream.
  Future<String> fetchSubtitleContent(int mediaId, String lang,
      {int start = 0}) async {
    final response = await _dio.get<String>(
      "/api/v1/media/$mediaId/subtitles/$lang.vtt",
      queryParameters: {"start": start},
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? "";
  }

  /// Start an HLS transcoding session and return its descriptor. The server
  /// blocks until the first segment is ready, so the returned [HlsSession.masterUrl]
  /// can be opened immediately by the player.
  Future<HlsSession> startHlsSession(
    int mediaId,
    String quality, {
    int startSeconds = 0,
    int audioIndex = 0,
  }) async {
    final stopwatch = Stopwatch()..start();
    final response = await _dio.post(
      "/api/v1/stream/$mediaId/start",
      queryParameters: {
        "quality": quality,
        "start": startSeconds,
        "audio": audioIndex,
      },
    );
    stopwatch.stop();
    print("ApiClient: startHlsSession took ${stopwatch.elapsedMilliseconds}ms "
        "for media $mediaId quality $quality audio $audioIndex");
    return HlsSession.fromJson(response.data as Map<String, dynamic>);
  }

  // Notify server to destroy an HLS transcoding session (kills FFmpeg + temp files)
  Future<void> destroyHlsSession(int mediaId, String sessionId) async {
    if (sessionId.isEmpty) return;
    try {
      await _dio.delete(getHlsDestroyUrl(mediaId, sessionId));
    } catch (_) {
      // Best-effort: the server reaper cleans up idle sessions anyway.
    }
  }

  // Set the server connection settings
  Future<void> setConnection(String serverUrl, {String? token}) async {
    // Normalize URL
    String formattedUrl = serverUrl.trim();
    if (!formattedUrl.startsWith("http://") &&
        !formattedUrl.startsWith("https://")) {
      formattedUrl = "http://$formattedUrl";
    }
    if (formattedUrl.endsWith("/")) {
      formattedUrl = formattedUrl.substring(0, formattedUrl.length - 1);
    }

    final previousUrl = _baseUrl;
    _baseUrl = formattedUrl;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_url", formattedUrl);

    if (token != null) {
      _token = token;
      await _writeToken(token);
    } else if (previousUrl != null && previousUrl != formattedUrl) {
      _token = null;
      await _deleteToken();
    }
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('server_url') ?? _defaultBaseUrl;
    _savedUsername = prefs.getString('last_username');
    _token = await _readToken();
    _configLoaded = true;
  }

  Future<void> clearAuth() async {
    _token = null;
    await _deleteToken();
  }

  // ==================== AUTH API ====================

  Future<Map<String, dynamic>> register(
      String username, String password) async {
    final response = await _dio.post("/api/auth/register", data: {
      "username": username,
      "password": password,
    });
    await saveLastUsername(username);
    return response.data as Map<String, dynamic>;
  }

  Future<User> login(String username, String password) async {
    final response = await _dio.post("/api/auth/login", data: {
      "username": username,
      "password": password,
    });

    final token = response.data["token"] as String;
    final userJson = response.data["user"] as Map<String, dynamic>;
    final user = User.fromJson(userJson);

    await setConnection(baseUrl, token: token);
    await saveLastUsername(user.username);
    return user;
  }

  Future<User> getMe() async {
    final response = await _dio.get("/api/auth/me");
    return User.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    try {
      await _dio.post("/api/auth/logout");
    } catch (_) {}
    await clearAuth();
  }

  // ==================== MEDIA API ====================

  Future<HomeResponse> getHome() async {
    final response = await _dio.get("/api/home");
    return HomeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<HomeMediaItem>> getMovies() async {
    final response = await _dio.get("/api/movies");
    return (response.data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Media>> getShows() async {
    final response = await _dio.get("/api/shows");
    return (response.data as List<dynamic>)
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Media>> getShowSeasons(int showId) async {
    final response = await _dio.get("/api/shows/$showId/seasons");
    return (response.data as List<dynamic>)
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HomeMediaItem>> getSeasonEpisodes(int seasonId) async {
    final response = await _dio.get("/api/seasons/$seasonId/episodes");
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

  Future<bool> sendProgress({
    required int mediaId,
    required int currentPositionSeconds,
    required int duration,
    required bool isFinished,
  }) async {
    final response = await _dio.post("/api/progress", data: {
      "media_id": mediaId,
      "current_position_seconds": currentPositionSeconds,
      "duration": duration,
      "is_finished": isFinished,
    });

    return response.data["is_finished"] as bool? ?? isFinished;
  }

  Future<Map<String, dynamic>> setMediaWatched(
      int mediaId, bool watched) async {
    final response = await _dio.post("/api/media/$mediaId/watched", data: {
      "watched": watched,
    });
    return response.data as Map<String, dynamic>;
  }

  Future<void> hideFromContinueWatching({int? movieId, int? showId}) async {
    final data = <String, dynamic>{};
    if (movieId != null) data['movie_id'] = movieId;
    if (showId != null) data['show_id'] = showId;
    await _dio.post('/api/continue-watching/hide', data: data);
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

  /// Fetches rich, Emby-style catalog details (cast, genres, rating, backdrop,
  /// crew…) for a movie or show, merging local library data with live TMDB.
  Future<MediaDetails> getMediaDetails(int mediaId) async {
    final response = await _dio.get("/api/media/$mediaId/details");
    return MediaDetails.fromJson(response.data as Map<String, dynamic>);
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
    final response = await _dio.get("/api/media/$mediaId/tracks");
    return MediaTracks.fromJson(response.data as Map<String, dynamic>);
  }

  Future<RequestCatalogPage> getRequestCatalog({
    required int page,
    required String type,
    String? query,
  }) async {
    final response = await _dio.get('/api/requests/catalog', queryParameters: {
      'page': page,
      'type': type,
      if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
    });
    return RequestCatalogPage.fromJson(response.data as Map<String, dynamic>);
  }

  Future<RequestMediaDetails> getRequestMediaDetails(
      int tmdbId, RequestMediaType type) async {
    final response = await _dio.get(
      '/api/requests/media/$tmdbId',
      queryParameters: {'type': type.name},
    );
    return RequestMediaDetails.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> requestMedia(
    RequestMediaItem media, {
    List<int>? seasons,
  }) async {
    await _dio.post('/api/requests', data: {
      'tmdbId': media.id,
      'mediaType': media.mediaType.name,
      'title': media.title,
      'posterPath': media.posterPath,
      if (seasons != null && seasons.isNotEmpty) 'seasons': seasons,
    });
  }

  // ==================== INDEXER API ====================

  Future<void> triggerScan() async {
    await _dio.post("/api/indexer/scan");
  }

  Future<void> triggerMetadataBackfill() async {
    await _dio.post("/api/indexer/metadata/backfill");
  }

  /// Fetches TMDB poster/overview for a single movie or show.
  Future<Media> enrichMediaMetadata(int mediaId) async {
    final response = await _dio.post("/api/media/$mediaId/metadata/enrich");
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
}

/// Combined indexer / subtitle-extraction status from the server.
class IndexerStatus {
  final bool isScanning;
  final bool isBackfillingMetadata;
  final bool isExtractingSubtitles;
  final SubtitleExtractionStats subtitleExtraction;

  IndexerStatus({
    required this.isScanning,
    required this.isBackfillingMetadata,
    required this.isExtractingSubtitles,
    required this.subtitleExtraction,
  });

  factory IndexerStatus.fromJson(Map<String, dynamic> json) {
    return IndexerStatus(
      isScanning: json["is_scanning"] as bool? ?? false,
      isBackfillingMetadata: json["is_backfilling_metadata"] as bool? ?? false,
      isExtractingSubtitles: json["is_extracting_subtitles"] as bool? ?? false,
      subtitleExtraction: SubtitleExtractionStats.fromJson(
        json["subtitle_extraction"] as Map<String, dynamic>? ?? {},
      ),
    );
  }

  bool get isBusy =>
      isScanning || isBackfillingMetadata || isExtractingSubtitles;
}

class SubtitleExtractionStats {
  final int total;
  final int processed;
  final int succeeded;
  final int failed;
  final int tracks;

  SubtitleExtractionStats({
    this.total = 0,
    this.processed = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.tracks = 0,
  });

  factory SubtitleExtractionStats.fromJson(Map<String, dynamic> json) {
    return SubtitleExtractionStats(
      total: json["total"] as int? ?? 0,
      processed: json["processed"] as int? ?? 0,
      succeeded: json["succeeded"] as int? ?? 0,
      failed: json["failed"] as int? ?? 0,
      tracks: json["tracks"] as int? ?? 0,
    );
  }
}
