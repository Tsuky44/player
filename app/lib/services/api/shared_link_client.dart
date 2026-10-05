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
  /// [origin] est l'adresse du serveur du lien, que l'app installée lit dans
  /// le lien collé. Sur le web elle est absente : la page vient de ce serveur.
  SharedLinkApiClient(this.code, {String? origin})
      : super(registry: _NoAccountRegistry()) {
    if (origin == null) return;
    // Comme un client épinglé : sans cela, la première requête chargerait la
    // dernière adresse saisie sur cet appareil, celle d'un autre serveur.
    _baseUrl = ServerAccount.normalizeUrl(origin);
    _configLoaded = true;
    _serverChosen = true;
  }

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

  /// L'épisode en cours de lecture dans le lien d'une saison ou d'une série ;
  /// nul pour un film ou un épisode, que le lien désigne seul.
  int? _episodeId;

  // Le code suffit comme clé : 128 bits d'aléa, il ne se répète pas d'un
  // serveur à l'autre.
  String get _viewerKey => 'onyx-share-viewer:$code';

  /// Une position par épisode dans une saison ou une série partagée.
  String _positionKey(int? episodeId) => episodeId == null
      ? 'onyx-share-position:$code'
      : 'onyx-share-position:$code:$episodeId';

  /// Ce que les routes de la lecture ajoutent pour nommer l'épisode lu.
  Map<String, dynamic> get _playing =>
      {if (_episodeId != null) 'media_id': _episodeId};

  /// Décrit le lien : faut-il un mot de passe, et sinon quel média il ouvre.
  Future<SharedMediaInfo> info() async {
    final data = await _shared('info', {'viewer': await _loadViewer()});
    return SharedMediaInfo.fromJson(data);
  }

  /// Décrit un lien protégé une fois son [password] donné, sans rien ouvrir :
  /// pour une saison ou une série, la liste des épisodes à choisir.
  Future<SharedMediaInfo> contents(String password) async {
    final data = await _shared('contents', {
      'password': password,
      'viewer': await _loadViewer(),
    });
    _password = password;
    return SharedMediaInfo.fromJson(data);
  }

  /// Ouvre le lien avec [password] : le serveur réserve un lien à usage
  /// unique à ce navigateur et délivre un premier ticket de lecture.
  /// [episodeId] désigne l'épisode voulu d'une saison ou d'une série.
  Future<({SharedMediaInfo media, int mediaId})> open(String password,
      {int? episodeId}) async {
    _password = password;
    _episodeId = episodeId;
    final data = await _shared('open', {
      'password': password,
      'viewer': await _loadViewer(),
      ..._playing,
    });
    await _rememberViewer(data['viewer'] as String? ?? '');
    _pending = _SharedTicket.fromJson(data);
    _ticket = _pending!.token;
    return (
      media: SharedMediaInfo.fromJson(data['media'] as Map<String, dynamic>),
      mediaId: data['media_id'] as int,
    );
  }

  /// Où ce navigateur s'était arrêté, en secondes : dans le média du lien, ou
  /// dans l'épisode [episodeId] d'une saison ou d'une série.
  Future<int> savedPosition({int? episodeId}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_positionKey(episodeId)) ?? 0;
  }

  @override
  Future<PlaybackAccess> openPlaybackAccess(int mediaId,
      {bool forDownload = false}) async {
    // Le premier ticket est celui de l'ouverture ; un lecteur qui en redemande
    // un (reprise après une coupure) rouvre le lien avec le même mot de passe.
    var ticket = _pending;
    _pending = null;
    if (ticket == null) {
      await open(_password, episodeId: _episodeId);
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
      _shared('tracks', {'viewer': _viewer, 'ticket': _ticket, ..._playing});

  @override
  Future<Map<String, dynamic>> getProgress(int mediaId) async => {
        'current_position_seconds':
            await savedPosition(episodeId: _episodeId),
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
    final positionKey = _positionKey(_episodeId);
    if (isFinished) {
      await prefs.remove(positionKey);
    } else {
      await prefs.setInt(positionKey, currentPositionSeconds);
    }
    final data = await _shared('progress', {
      'viewer': _viewer,
      'ticket': _ticket,
      ..._playing,
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
