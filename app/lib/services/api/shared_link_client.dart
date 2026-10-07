part of '../api_client.dart';

/// Le client du visiteur d'un lien de partage public (ADR-0037), sans compte.
///
/// Il fait tourner le lecteur Onyx habituel sur les routes `/api/shared/*` :
/// le ticket de lecture vient du lien et non d'un compte, et ce que le lecteur
/// demande d'ordinaire à un compte est rendu vide (historique, journal) ou
/// gardé sur l'appareil (progression). Pour une saison ou une série, les
/// saisons, les épisodes et l'épisode suivant sont répondus depuis ce que le
/// lien a décrit ([SharedShow]), sans requête. Le reste (HLS, Direct Play,
/// sous-titres, aperçus) passe déjà par le ticket seul.
///
/// Aucun compte n'est lu ni écrit : le registre est vide, même si ce
/// navigateur est par ailleurs connecté à ce serveur.
class SharedLinkApiClient extends ApiClient {
  /// [origin] est l'adresse du serveur du lien, que l'app installée lit dans
  /// le lien collé. Sur le web elle est absente : la page vient de ce serveur.
  SharedLinkApiClient(this.code, {String? origin, super.httpClient})
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

  /// Le ticket de chaque média en lecture : il prouve le mot de passe aux
  /// routes qui le demandent. Un par média et non un seul : en passant à
  /// l'épisode suivant, l'ancien lecteur envoie encore sa dernière position
  /// pendant que le nouveau s'ouvre.
  final Map<int, String> _tickets = {};

  /// La saison ou la série que le lien ouvre, une fois décrite.
  SharedMediaInfo? _collection;

  /// Vrai dès que le lien s'avère être celui d'une saison ou d'une série : les
  /// routes de la lecture nomment alors l'épisode.
  bool _isCollection = false;

  /// La position, les épisodes vus et le dernier regardé, gardés sur
  /// l'appareil.
  late final SharedLinkProgressStore progress = SharedLinkProgressStore(code);

  /// Passe à vrai quand le serveur annonce le lien détruit, vu.
  final ValueNotifier<bool> consumed = ValueNotifier(false);

  @override
  bool get isGuest => true;

  // Le code suffit comme clé : 128 bits d'aléa, il ne se répète pas d'un
  // serveur à l'autre.
  String get _viewerKey => 'onyx-share-viewer:$code';

  /// [mediaId] vu comme un épisode du lien ; nul pour un film ou un épisode,
  /// que le lien désigne seul.
  int? _episodeOf(int mediaId) => _isCollection ? mediaId : null;

  /// Ce que les routes de la lecture ajoutent pour nommer l'épisode lu.
  Map<String, dynamic> _playing(int mediaId) =>
      {if (_isCollection) 'media_id': mediaId};

  /// Décrit le lien : faut-il un mot de passe, et sinon quel média il ouvre.
  Future<SharedMediaInfo> info() async {
    final data = await _shared('info', {'viewer': await _loadViewer()});
    return SharedMediaInfo.fromJson(data);
  }

  /// La saison ou la série [info] avec l'avancement gardé sur l'appareil,
  /// telle que la page du lien la montre. Le client la retient : c'est d'elle
  /// que le lecteur tient ses saisons, ses épisodes et l'épisode suivant.
  Future<SharedShow> describe(SharedMediaInfo info) async {
    _collection = info;
    _isCollection = true;
    return SharedShow(
        info, await progress.snapshot(info.episodes.map((e) => e.id)));
  }

  Future<SharedShow?> _show() async {
    final info = _collection;
    return info == null ? null : describe(info);
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
    if (episodeId != null) _isCollection = true;
    final data = await _shared('open', {
      'password': password,
      'viewer': await _loadViewer(),
      if (episodeId != null) 'media_id': episodeId,
    });
    await _rememberViewer(data['viewer'] as String? ?? '');
    final ticket = _pending = _SharedTicket.fromJson(data);
    _tickets[ticket.mediaId] = ticket.token;
    return (
      media: SharedMediaInfo.fromJson(data['media'] as Map<String, dynamic>),
      mediaId: ticket.mediaId,
    );
  }

  /// Où ce navigateur s'était arrêté, en secondes : dans le média du lien, ou
  /// dans l'épisode [episodeId] d'une saison ou d'une série.
  Future<int> savedPosition({int? episodeId}) =>
      progress.position(episodeId: episodeId);

  @override
  Future<PlaybackAccess> openPlaybackAccess(int mediaId,
      {bool forDownload = false}) async {
    // Le premier ticket est celui de l'ouverture. Un lecteur qui en redemande
    // un (reprise après une coupure), ou qui passe à un autre épisode du lien,
    // rouvre le lien avec le même mot de passe : c'est le serveur qui vérifie
    // que cet épisode en fait partie.
    var ticket = _pending;
    _pending = null;
    if (ticket == null || ticket.mediaId != mediaId) {
      await open(_password, episodeId: _episodeOf(mediaId));
      ticket = _pending!;
      _pending = null;
    }
    final token = ticket.token;
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
      _shared('tracks', {
        'viewer': _viewer,
        'ticket': _tickets[mediaId],
        ..._playing(mediaId),
      });

  @override
  Future<Map<String, dynamic>> getProgress(int mediaId) async => {
        'current_position_seconds':
            await savedPosition(episodeId: _episodeOf(mediaId)),
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
    await progress.record(
      episodeId: _episodeOf(mediaId),
      positionSeconds: currentPositionSeconds,
      finished: isFinished,
    );
    final data = await _shared('progress', {
      'viewer': _viewer,
      'ticket': _tickets[mediaId],
      ..._playing(mediaId),
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
  Future<List<VideoChapter>> getEpisodeChapters(int episodeId) async =>
      const [];

  @override
  Future<Map<String, dynamic>> getMediaDetailsJson(int mediaId) async =>
      {'id': mediaId};

  // Ce qu'une saison ou une série partagée sait dire d'elle-même, comme à un
  // compte (ADR-0037 §10) : le lecteur enchaîne sur l'épisode suivant, liste
  // les épisodes et habille son titre sans rien demander de plus au serveur.

  /// L'épisode suivant du lien. Jamais de saison à demander ni d'épisode à
  /// venir : un visiteur ne peut rien réclamer au serveur.
  @override
  Future<NextEpisodeResponse> getNextEpisode(int episodeId) async {
    final next = (await _show())?.after(episodeId);
    return NextEpisodeResponse(hasNext: next != null, episode: next);
  }

  @override
  Future<EpisodeTimestamps> getEpisodeTimestamps(int episodeId) async {
    final episode = (await _show())?.episode(episodeId);
    return EpisodeTimestamps(
      introStart: episode?.introStart ?? 0,
      introEnd: episode?.introEnd ?? 0,
      outroStart: episode?.outroStart ?? 0,
      outroEnd: episode?.outroEnd ?? 0,
    );
  }

  @override
  Future<List<Media>> getShowSeasons(int showId) async =>
      (await _show())?.seasons ?? const [];

  @override
  Future<List<HomeMediaItem>> getSeasonEpisodes(int seasonId) async =>
      (await _show())?.episodesOf(seasonId) ?? const [];

  /// La fiche de la série du lien, pour le logo du lecteur ; rien de plus que
  /// son identifiant pour tout autre média.
  @override
  Future<MediaDetails> getMediaDetails(int mediaId) async {
    final details = _collection?.details;
    if (details != null && details.id == mediaId) return details;
    return MediaDetails(id: mediaId, type: MediaType.show, title: '');
  }

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
              ? tr('Impossible de joindre le serveur. Vérifiez votre connexion.')
              : tr('Le serveur n’a pas pu ouvrir ce lien. Réessayez.');
      throw SharedLinkException(error.response?.statusCode ?? 0, message);
    }
  }
}

class _SharedTicket {
  const _SharedTicket(this.mediaId, this.token, this.expiresAt);

  factory _SharedTicket.fromJson(Map<String, dynamic> json) => _SharedTicket(
        json['media_id'] as int,
        json['ticket'] as String,
        DateTime.parse(json['expires_at'] as String),
      );

  /// Le média que ce ticket ouvre, et lui seul.
  final int mediaId;
  final String token;
  final DateTime expiresAt;
}

/// Un registre sans compte ni stockage : le visiteur d'un lien n'est connecté
/// à rien, même si ce navigateur l'est par ailleurs à ce serveur.
class _NoAccountRegistry extends ServerRegistry {
  @override
  Future<void> load() async {}
}
