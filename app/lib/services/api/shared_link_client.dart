part of '../api_client.dart';

/// Le client du visiteur d'un lien de partage public (ADR-0037), sans compte.
///
/// Il fait tourner le lecteur Onyx habituel sur les routes `/api/shared/*` :
/// le ticket de lecture vient du lien et non d'un compte, et tout ce que le
/// lecteur demande d'ordinaire à un compte — progression, historique, épisode
/// suivant, journal — est rendu vide ou gardé sur l'appareil. Le reste
/// (HLS, Direct Play, sous-titres, aperçus) passe déjà par le ticket seul.
///
/// Aucun compte n'est lu ni écrit : le registre est vide, même si ce
/// navigateur est par ailleurs connecté à ce serveur.
class SharedLinkApiClient extends ApiClient {
  SharedLinkApiClient(this.code) : super(registry: _NoAccountRegistry());

  /// Le code du lien, lu dans le fragment de l'adresse.
  final String code;

  String? _viewer;
  String _password = '';

  /// Le ticket délivré par la dernière ouverture, pas encore remis au lecteur.
  _SharedTicket? _pending;

  /// Le ticket de la lecture en cours : il prouve le mot de passe aux routes
  /// qui le demandent.
  String? _ticket;

  /// Passe à vrai quand le serveur annonce le lien détruit, vu.
  final ValueNotifier<bool> consumed = ValueNotifier(false);

  @override
  bool get isGuest => true;

  String get _viewerKey => 'onyx-share-viewer:$code';
  String get _positionKey => 'onyx-share-position:$code';

  /// Décrit le lien : faut-il un mot de passe, et sinon quel média il ouvre.
  Future<SharedMediaInfo> info() async {
    final data = await _shared('info', {'viewer': await _loadViewer()});
    return SharedMediaInfo.fromJson(data);
  }

  /// Ouvre le lien avec [password] : le serveur réserve un lien à usage
  /// unique à ce navigateur et délivre un premier ticket de lecture.
  Future<({SharedMediaInfo media, int mediaId})> open(String password) async {
    _password = password;
    final data = await _shared('open', {
      'password': password,
      'viewer': await _loadViewer(),
    });
    await _rememberViewer(data['viewer'] as String? ?? '');
    _pending = _SharedTicket.fromJson(data);
    _ticket = _pending!.token;
    return (
      media: SharedMediaInfo.fromJson(data['media'] as Map<String, dynamic>),
      mediaId: data['media_id'] as int,
    );
  }

  /// Où ce navigateur s'était arrêté, en secondes.
  Future<int> savedPosition() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_positionKey) ?? 0;
  }

  @override
  Future<PlaybackAccess> openPlaybackAccess(int mediaId) async {
    // Le premier ticket est celui de l'ouverture ; un lecteur qui en redemande
    // un (reprise après une coupure) rouvre le lien avec le même mot de passe.
    var ticket = _pending;
    _pending = null;
    if (ticket == null) {
      await open(_password);
      ticket = _pending!;
      _pending = null;
    }
    final token = ticket.token;
    _ticket = token;
    return PlaybackAccess(
      origin: baseUrl,
      mediaId: mediaId,
      token: token,
      expiresAt: ticket.expiresAt,
      renew: () async {
        final data =
            await _shared('renew', {'viewer': _viewer, 'ticket': token});
        return DateTime.parse(data['expires_at'] as String);
      },
      revoke: () async {
        await _shared('close', {'ticket': token});
      },
    );
  }

  @override
  Future<Map<String, dynamic>> getMediaTracksJson(int mediaId) =>
      _shared('tracks', {'viewer': _viewer, 'ticket': _ticket});

  @override
  Future<Map<String, dynamic>> getProgress(int mediaId) async => {
        'current_position_seconds': await savedPosition(),
        'is_finished': false,
      };

  /// La position reste sur l'appareil ; le serveur ne l'entend que pour
  /// détruire un lien à usage unique au seuil « vu ».
  @override
  Future<bool> sendProgress({
    required int mediaId,
    required int currentPositionSeconds,
    required int duration,
    required bool isFinished,
    DateTime? clientUpdatedAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (isFinished) {
      await prefs.remove(_positionKey);
    } else {
      await prefs.setInt(_positionKey, currentPositionSeconds);
    }
    final data = await _shared('progress', {
      'viewer': _viewer,
      'ticket': _ticket,
      'position_seconds': currentPositionSeconds,
      'duration_seconds': duration,
    });
    if (data['consumed'] == true) consumed.value = true;
    return isFinished;
  }

  // Ce qui suppose un compte : rien à demander au serveur.

  @override
  Future<void> reportPlayback({
    required int mediaId,
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
    required PlayMethod playMethod,
    String quality = '',
    String event = 'progress',
  }) async {}

  @override
  Future<PlaybackHandoff?> getPlaybackHandoff() async => null;

  @override
  Future<void> uploadPlaybackLogs(List<LogEntry> lines,
      {Map<String, dynamic>? stats}) async {}

  @override
  Future<List<MediaSubtitleTrack>> forceMediaSubtitleExtract(int mediaId,
          {bool force = true}) async =>
      const [];

  @override
  Future<NextEpisodeResponse> getNextEpisode(int episodeId) async =>
      NextEpisodeResponse.fromJson(const {});

  @override
  Future<EpisodeTimestamps> getEpisodeTimestamps(int episodeId) async =>
      EpisodeTimestamps.fromJson(const {});

  @override
  Future<List<VideoChapter>> getEpisodeChapters(int episodeId) async =>
      const [];

  @override
  Future<List<Media>> getShowSeasons(int showId) async => const [];

  @override
  Future<List<HomeMediaItem>> getSeasonEpisodes(int seasonId) async => const [];

  @override
  Future<Map<String, dynamic>> getMediaDetailsJson(int mediaId) async =>
      {'id': mediaId};

  Future<String> _loadViewer() async {
    if (_viewer != null) return _viewer!;
    final prefs = await SharedPreferences.getInstance();
    return _viewer = prefs.getString(_viewerKey) ?? '';
  }

  Future<void> _rememberViewer(String viewer) async {
    _viewer = viewer;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_viewerKey, viewer);
  }

  /// Un appel public du lien. Le refus du serveur devient une
  /// [SharedLinkException] qui porte sa phrase, à montrer telle quelle.
  Future<Map<String, dynamic>> _shared(
      String route, Map<String, dynamic> body) async {
    try {
      final response =
          await _dio.post('/api/shared/$route', data: {'code': code, ...body});
      final data = response.data;
      return data is Map<String, dynamic> ? data : const {};
    } on DioException catch (error) {
      final data = error.response?.data;
      final message = data is Map && data['error'] is String
          ? data['error'] as String
          : error.response == null
              ? 'Impossible de joindre le serveur. Vérifiez votre connexion.'
              : 'Le serveur n’a pas pu ouvrir ce lien. Réessayez.';
      throw SharedLinkException(error.response?.statusCode ?? 0, message);
    }
  }
}

class _SharedTicket {
  const _SharedTicket(this.token, this.expiresAt);

  factory _SharedTicket.fromJson(Map<String, dynamic> json) => _SharedTicket(
        json['ticket'] as String,
        DateTime.parse(json['expires_at'] as String),
      );

  final String token;
  final DateTime expiresAt;
}

/// Un registre sans compte ni stockage : le visiteur d'un lien n'est connecté
/// à rien, même si ce navigateur l'est par ailleurs à ce serveur.
class _NoAccountRegistry extends ServerRegistry {
  @override
  Future<void> load() async {}
}
