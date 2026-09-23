part of '../api_client.dart';

/// Activité, appareils et statistiques.
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _ActivityEndpoints {
  Dio get _dio;

  // ==================== ACTIVITÉ, APPAREILS, STATISTIQUES ====================

  /// Signal de lecture : ce que ce lecteur lit, où il en est, en pause ou non.
  /// Le serveur en tire les lectures en cours du tableau de bord et
  /// l'historique. Voir `server/handlers/activity.go`.
  Future<void> reportPlayback({
    required int mediaId,
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
    required PlayMethod playMethod,
    String quality = '',
    String event = 'progress',
  }) async {
    await _dio.post('/api/playing', data: {
      'media_id': mediaId,
      'position_seconds': positionSeconds,
      'duration_seconds': durationSeconds,
      'paused': paused,
      'play_method': playMethod.wire,
      if (quality.isNotEmpty) 'quality': quality,
      'event': event,
    });
  }

  /// Ce que ce compte lit sur ses autres appareils, pour le reprendre ici.
  Future<List<RemotePlayback>> getMyRemotePlaybacks() async {
    final response = await _dio.get('/api/me/now-playing');
    final data = response.data;
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(RemotePlayback.tryParse)
        .whereType<RemotePlayback>()
        .toList();
  }

  /// Non nul quand la lecture de ce lecteur a été reprise sur un autre
  /// appareil. Voir `server/handlers/playback_handoff.go`.
  Future<PlaybackHandoff?> getPlaybackHandoff() async {
    final response = await _dio.get('/api/playing/handoff');
    final data = response.data;
    if (response.statusCode == 204 || data is! Map<String, dynamic>) {
      return null;
    }
    return PlaybackHandoff.fromJson(data);
  }

  Future<List<NowPlayingSession>> getNowPlaying() async {
    final response = await _dio.get('/api/admin/activity');
    return (response.data as List)
        .map((e) => NowPlayingSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PlaybackHistoryEntry>> getPlaybackHistory({
    int limit = 50,
    int? beforeId,
    int? userId,
  }) async {
    final response = await _dio.get('/api/admin/history', queryParameters: {
      'limit': limit,
      if (beforeId != null) 'before_id': beforeId,
      if (userId != null) 'user_id': userId,
    });
    return (response.data as List)
        .map((e) => PlaybackHistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> clearPlaybackHistory() async {
    await _dio.delete('/api/admin/history');
  }

  /// Envoie le journal de la lecture en cours.
  ///
  /// Le serveur le rattache à la séance ouverte pour cette session, donc
  /// l'appel doit précéder le signal d'arrêt. Un serveur plus ancien n'a pas
  /// cette route : l'appelant traite l'échec comme sans conséquence, une
  /// lecture ne dépend pas de son journal.
  ///
  /// Rien à filtrer ici quand le serveur a coupé la conservation : le réglage
  /// vit derrière `manage_settings`, qu'un compte ordinaire n'a pas, donc ce
  /// client ne peut pas le connaître. C'est le serveur qui écarte la tranche,
  /// par un 204 — la seule place où la réponse est sûre.
  Future<void> uploadPlaybackLogs(
    List<LogEntry> lines, {
    Map<String, dynamic>? stats,
  }) async {
    if (lines.isEmpty && stats == null) return;
    await _dio.post('/api/playing/logs', data: {
      'lines': [
        for (final line in lines)
          {
            'at': line.time.toUtc().toIso8601String(),
            'level': line.level == LogLevel.error ? 'error' : 'info',
            'message': line.message,
          },
      ],
      if (stats != null) 'stats': stats,
    });
  }

  /// Ce qu'une lecture passée a enregistré. Vide pour une lecture faite par un
  /// client qui n'envoyait pas encore son journal.
  Future<PlaybackLogs> getPlaybackLogs(int historyId) async {
    final response = await _dio.get('/api/admin/history/$historyId/logs');
    return PlaybackLogs.fromJson(response.data as Map<String, dynamic>);
  }

  /// Statistiques du serveur entier, ou d'un compte avec [userId]. Les jours
  /// sont découpés dans le fuseau de cet appareil.
  Future<PlaybackStats> getPlaybackStats({int days = 30, int? userId}) async {
    final response = await _dio.get('/api/admin/stats', queryParameters: {
      'days': days,
      'tz_offset': DateTime.now().timeZoneOffset.inMinutes,
      if (userId != null) 'user_id': userId,
    });
    return PlaybackStats.fromJson(response.data as Map<String, dynamic>);
  }

  Future<PlaybackStats> getMyPlaybackStats({int days = 30}) async {
    final response = await _dio.get('/api/me/stats', queryParameters: {
      'days': days,
      'tz_offset': DateTime.now().timeZoneOffset.inMinutes,
    });
    return PlaybackStats.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<ConnectedDevice>> getMyDevices() async {
    final response = await _dio.get('/api/me/devices');
    return (response.data as List)
        .map((e) => ConnectedDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> revokeMyDevice(int id) async {
    await _dio.delete('/api/me/devices/$id');
  }

  Future<List<ConnectedDevice>> getAllDevices() async {
    final response = await _dio.get('/api/admin/devices');
    return (response.data as List)
        .map((e) => ConnectedDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> revokeAnyDevice(int id) async {
    await _dio.delete('/api/admin/devices/$id');
  }

  Future<ServerInfo> getServerInfo() async {
    final response = await _dio.get('/api/admin/server');
    return ServerInfo.fromJson(response.data as Map<String, dynamic>);
  }
}
