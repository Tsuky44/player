import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

/// Holds the result of starting an HLS transcoding session.
class HlsSession {
  final String sessionId;
  final String playlistContent;
  final double totalDuration; // full media duration in seconds

  HlsSession({
    required this.sessionId,
    required this.playlistContent,
    required this.totalDuration,
  });
}

class ApiClient {
  static const String _defaultBaseUrl = "http://10.0.2.2:8080"; // Default emulator localhost IP
  final Dio _dio = Dio();
  final _secureStorage = const FlutterSecureStorage();
  
  String? _baseUrl;
  String? _token;

  ApiClient() {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        // Automatically inject current base URL
        if (_baseUrl != null) {
          options.baseUrl = _baseUrl!;
        } else {
          await _loadConfig();
          options.baseUrl = _baseUrl ?? _defaultBaseUrl;
        }

        // Inject Authorization Header
        if (_token != null) {
          options.headers["Authorization"] = "Bearer $_token";
        } else {
          final savedToken = await _secureStorage.read(key: "auth_token");
          if (savedToken != null) {
            _token = savedToken;
            options.headers["Authorization"] = "Bearer $_token";
          }
        }

        options.connectTimeout = const Duration(seconds: 10);
        options.receiveTimeout = const Duration(seconds: 30);
        
        return handler.next(options);
      },
      onError: (DioException e, handler) {
        // Global error logging
        print("API Error [${e.requestOptions.method}] ${e.requestOptions.path}: ${e.message}");
        return handler.next(e);
      }
    ));
  }

  // Get current active base URL
  String get baseUrl => _baseUrl ?? _defaultBaseUrl;

  // Stream URL generator (Direct Play)
  String getStreamUrl(int mediaId) {
    return "$baseUrl/stream?media_id=$mediaId";
  }

  // HLS Transcoding URL generator
  String getHlsStreamUrl(int mediaId, String quality, {int startSeconds = 0}) {
    return "$baseUrl/api/v1/stream/$mediaId/master.m3u8?quality=$quality&start=$startSeconds";
  }

  // HLS session destroy URL (to notify server on stop)
  String getHlsDestroyUrl(int mediaId, String sessionId) {
    return "$baseUrl/api/v1/stream/$mediaId/$sessionId";
  }

  // Start an HLS session: fetches the master playlist, extracts the session ID
  // and total media duration from response headers, and returns both.
  Future<HlsSession> startHlsSession(int mediaId, String quality, {int startSeconds = 0}) async {
    final url = getHlsStreamUrl(mediaId, quality, startSeconds: startSeconds);
    final response = await _dio.get(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final sessionId = response.headers.value('X-Session-Id') ?? '';
    final durationStr = response.headers.value('X-Total-Duration') ?? '0';
    final totalDuration = double.tryParse(durationStr) ?? 0.0;
    final playlistContent = response.data as String;
    return HlsSession(
      sessionId: sessionId,
      playlistContent: playlistContent,
      totalDuration: totalDuration,
    );
  }

  // Notify server to destroy an HLS transcoding session
  Future<void> destroyHlsSession(int mediaId, String sessionId) async {
    try {
      await _dio.delete(getHlsDestroyUrl(mediaId, sessionId));
    } catch (_) {
      // Best-effort: server reaper will clean up anyway
    }
  }

  // Set the server connection settings
  Future<void> setConnection(String serverUrl, {String? token}) async {
    // Normalize URL
    String formattedUrl = serverUrl.trim();
    if (!formattedUrl.startsWith("http://") && !formattedUrl.startsWith("https://")) {
      formattedUrl = "http://$formattedUrl";
    }
    if (formattedUrl.endsWith("/")) {
      formattedUrl = formattedUrl.substring(0, formattedUrl.length - 1);
    }

    _baseUrl = formattedUrl;
    _token = token;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_url", formattedUrl);

    if (token != null) {
      await _secureStorage.write(key: "auth_token", value: token);
    } else {
      await _secureStorage.delete(key: "auth_token");
    }
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString("server_url") ?? _defaultBaseUrl;
    _token = await _secureStorage.read(key: "auth_token");
  }

  Future<void> clearAuth() async {
    _token = null;
    await _secureStorage.delete(key: "auth_token");
  }

  // ==================== AUTH API ====================

  Future<Map<String, dynamic>> register(String username, String password) async {
    final response = await _dio.post("/api/auth/register", data: {
      "username": username,
      "password": password,
    });
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
    return data.map((json) => VideoChapter.fromJson(json as Map<String, dynamic>)).toList();
  }

  // ==================== INDEXER API ====================

  Future<void> triggerScan() async {
    await _dio.post("/api/indexer/scan");
  }

  Future<bool> getScanStatus() async {
    final response = await _dio.get("/api/indexer/status");
    return response.data["is_scanning"] as bool? ?? false;
  }
}
