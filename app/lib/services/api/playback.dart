part of '../api_client.dart';

/// Lecture : adresses de flux, ticket de lecture et sessions HLS.
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _PlaybackEndpoints {
  Dio get _dio;
  String get baseUrl;
  String? get _token;
  bool get _configLoaded;
  Future<void> _loadConfig();

  // Stream URL generator (Direct Play)
  String getStreamUrl(int mediaId, {PlaybackAccess? access}) {
    if (access != null && access.mediaId != mediaId) {
      throw StateError('Média différent du ticket');
    }
    final url = "${access?.origin ?? baseUrl}/stream?media_id=$mediaId";
    return access?.protect(url) ?? url;
  }

  /// [forDownload] demande un ticket d'échéance longue : sur iPhone, un
  /// téléchargement continue écran verrouillé sans que l'app puisse le
  /// renouveler (ADR-0040). Un serveur qui ne connaît pas `purpose` l'ignore.
  Future<PlaybackAccess> openPlaybackAccess(int mediaId,
      {bool forDownload = false}) async {
    if (!_configLoaded) await _loadConfig();
    final scope = _PlaybackRequestScope(baseUrl, _token);
    Options scoped(String method) => Options(
        method: method,
        followRedirects: false,
        extra: {'playbackScope': scope});
    Response<dynamic> response;
    try {
      response = await _dio.request('/api/playback/tickets',
          data: {
            'media_id': mediaId,
            if (forDownload) 'purpose': 'download',
          },
          options: scoped('POST'));
    } on DioException catch (error) {
      if (error.response?.statusCode != 404 &&
          error.response?.statusCode != 405) {
        rethrow;
      }
      // A missing media on a new server also returns 404. Only an explicit
      // legacy ping permits old public URLs; auth/timeouts never do.
      final ping = await _dio.request('/api/ping', options: scoped('GET'));
      final info = ServerCapabilities.tryParse(ping.data);
      if (info == null || info.playbackTicketVersion != null) {
        rethrow;
      }
      return PlaybackAccess(
          origin: scope.origin,
          mediaId: mediaId,
          token: null,
          expiresAt: null,
          renew: () async => DateTime.now(),
          revoke: () async {});
    }
    final data = response.data as Map<String, dynamic>;
    final token = data['ticket'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw StateError('Ticket de lecture invalide');
    }
    return PlaybackAccess(
      origin: scope.origin,
      mediaId: mediaId,
      token: token,
      expiresAt: DateTime.parse(data['expires_at'] as String),
      renew: () async {
        final result = await _dio.request('/api/playback/tickets',
            data: {'ticket': token}, options: scoped('PUT'));
        return DateTime.parse(result.data['expires_at'] as String);
      },
      revoke: () async {
        await _dio.request('/api/playback/tickets',
            data: {'ticket': token}, options: scoped('DELETE'));
      },
    );
  }

  // HLS session destroy URL (to notify server on stop)
  String getHlsDestroyUrl(int mediaId, String sessionId,
      {PlaybackAccess? access}) {
    final url =
        "${access?.origin ?? baseUrl}/api/v1/stream/$mediaId/$sessionId";
    return access?.protect(url) ?? url;
  }

  /// URL of an external WebVTT subtitle for a given language. [start] shifts the
  /// timeline to match an HLS stream that begins at an offset; Direct Play uses 0.
  String getSubtitleUrl(int mediaId, String lang,
      {int start = 0, PlaybackAccess? access}) {
    // URL ends in ".vtt" so libmpv/media_kit detects the WebVTT parser from the
    // extension; without it the external track silently fails to load.
    final url =
        "${access?.origin ?? baseUrl}/api/v1/media/$mediaId/subtitles/${Uri.encodeComponent(lang)}.vtt?start=$start";
    return access?.protect(url) ?? url;
  }

  /// Spacing of the timeline stills for a media, as JSON. Also what starts the
  /// server filling them in, which is why the player only calls it once the
  /// first frame is on screen.
  Future<Map<String, dynamic>> openTimelinePreviews(int mediaId,
      {required PlaybackAccess access}) async {
    final response = await _dio.post(
      access.protect("${access.origin}/api/v1/media/$mediaId/previews"),
      options: Options(extra: {'playbackMedia': true}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// One timeline still, as JPEG bytes.
  Future<Uint8List> fetchTimelinePreview(int mediaId, int index,
      {required PlaybackAccess access}) async {
    final response = await _dio.get<List<int>>(
      access.protect("${access.origin}/api/v1/media/$mediaId/previews/$index.jpg"),
      options: Options(
          responseType: ResponseType.bytes, extra: {'playbackMedia': true}),
    );
    final data = response.data;
    if (data == null || data.isEmpty) throw StateError('Empty preview');
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  /// Download the raw WebVTT text for a subtitle. Fetching it ourselves and
  /// injecting via SubtitleTrack.data() is far more reliable than asking mpv to
  /// fetch a URL while it is already busy pulling an HLS stream.
  Future<String> fetchSubtitleContent(int mediaId, String lang,
      {int start = 0, PlaybackAccess? access}) async {
    final lease = access ?? await openPlaybackAccess(mediaId);
    try {
      final response = await _dio.get<String>(
        getSubtitleUrl(mediaId, lang, start: start, access: lease),
        options: Options(
            responseType: ResponseType.plain, extra: {'playbackMedia': true}),
      );
      return response.data ?? "";
    } finally {
      if (access == null) await lease.close();
    }
  }

  /// Start an HLS transcoding session and return its descriptor. The server
  /// blocks until the first segment is ready, so the returned [HlsSession.masterUrl]
  /// can be opened immediately by the player.
  Future<HlsSession> startHlsSession(
    int mediaId,
    String quality, {
    int startSeconds = 0,
    int audioIndex = 0,
    int burnSubtitleIndex = -1,
    PlaybackAccess? access,
    PlaybackCapabilities? capabilities,
  }) async {
    final stopwatch = Stopwatch()..start();
    final response = await _dio.post(
      "${access?.origin ?? baseUrl}/api/v1/stream/$mediaId/start",
      options: Options(extra: {'playbackMedia': true}),
      queryParameters: {
        "quality": quality,
        "start": startSeconds,
        "audio": audioIndex,
        // Bitmap subtitles have no out-of-band form, so the transcoder paints
        // the chosen one into the video. -1 means none.
        "burnsub": burnSubtitleIndex,
        // Ce client rouvre une session pour reculer au-delà de ce qu'elle a
        // gardé (retain_seconds) : le serveur peut effacer le reste.
        "purge": 1,
        ...?access?.query,
        // What this device can decode and play back. Without it the server
        // assumes the weakest client it has ever had to serve — H.264 8-bit and
        // stereo AAC — and re-encodes a file this one could have taken as it is.
        // Celles du moteur qui lira la session quand ce n'est pas celui de
        // l'appareil — AVPlayer à côté de mpv sur iPhone et Mac (ADR-0035).
        ...(capabilities ?? PlaybackCapabilitiesResolver.current)
            .toQueryParameters(),
      },
    );
    stopwatch.stop();
    final session = HlsSession.fromJson(response.data as Map<String, dynamic>);
    // A returned URL must remain on the issuing origin. The server supplies
    // the URL, but it must not accidentally send its ticket to another host.
    if (access != null) access.protect(session.masterUrl);
    // Logs both what was ASKED (startSeconds) and what the server CONFIRMS
    // (session.startOffset) side by side — the fastest way to tell whether a
    // seek landing at the wrong position is a client bug (mismatch here) or
    // something downstream (the two agree, but playback still drifts).
    debugPrint(
        "ApiClient: startHlsSession took ${stopwatch.elapsedMilliseconds}ms "
        "for media $mediaId quality $quality audio $audioIndex "
        "requestedStart=${startSeconds}s confirmedStart=${session.startOffset}s "
        "video=${session.videoMode}"
        "${session.videoReason.isEmpty ? '' : ' (${session.videoReason})'} "
        "session=${session.sessionId}");
    return session;
  }

  // Notify server to destroy an HLS transcoding session (kills FFmpeg + temp files)
  Future<void> destroyHlsSession(int mediaId, String sessionId,
      {PlaybackAccess? access}) async {
    if (sessionId.isEmpty) return;
    try {
      await _dio.delete(getHlsDestroyUrl(mediaId, sessionId, access: access),
          options: Options(extra: {'playbackMedia': true}));
    } catch (_) {
      // Best-effort: the server reaper cleans up idle sessions anyway.
    }
  }

  /// Points the client at an address, without claiming an account there.
  ///
  /// C'est le chemin de l'écran de connexion : on désigne un serveur avant de
  /// savoir si on y a un compte. Si l'adresse correspond à un compte déjà
  /// enregistré, elle le réactive — sinon la session en cours est **laissée
  /// intacte en mémoire de registre**, mais le jeton cesse d'être envoyé : le
  /// présenter à un autre serveur reviendrait à lui confier une session qui ne
  /// le concerne pas.
}
