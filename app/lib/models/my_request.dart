import 'media_request.dart';

/// Où en est une demande chez MediaHub (ou OnyxHub). `approved` n'existe pas
/// dans [RequestMediaStatus] : la demande est partie vers Radarr/Sonarr, rien
/// n'est encore en téléchargement. `declined` : refusée, avec un motif.
enum MyRequestStatus { pending, approved, processing, partial, available, declined }

MyRequestStatus _statusFrom(String? raw) => MyRequestStatus.values
    .firstWhere((s) => s.name == raw, orElse: () => MyRequestStatus.pending);

/// L'état de la demande d'une saison d'un lot.
class MyRequestSeason {
  const MyRequestSeason({required this.number, required this.status});

  final int number;
  final MyRequestStatus status;

  factory MyRequestSeason.fromJson(Map<String, dynamic> json) =>
      MyRequestSeason(
        number: (json['seasonNumber'] as num?)?.toInt() ?? 0,
        status: _statusFrom(json['status'] as String?),
      );
}

/// Une demande du compte, lue par `GET /api/requests/mine` (ADR-0073,
/// ADR-0089). Le serveur regroupe en un lot les saisons d'une série demandées
/// par un même compte ; MediaHub, lui, écrit une ligne par saison.
class MyRequest {
  const MyRequest({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    required this.posterPath,
    required this.seasons,
    required this.status,
    required this.requestedAt,
    required this.progress,
    this.requestIds = const [],
    this.seasonStatuses = const [],
    this.updatedAt,
    this.waitingMessage,
    this.releaseDate,
    this.note,
    this.requester,
  });

  final int tmdbId;
  final RequestMediaType mediaType;
  final String title;
  final String? posterPath;
  final List<int> seasons;
  final MyRequestStatus status;
  final DateTime? requestedAt;

  /// 0 à 100 pendant le téléchargement, null sinon (MediaHub v1 ne le donne
  /// pas encore).
  final double? progress;

  /// Les lignes MediaHub du lot, que la modération traite ensemble. Vide avec
  /// OnyxHub.
  final List<int> requestIds;

  /// L'état saison par saison, quand le compagnon le donne.
  final List<MyRequestSeason> seasonStatuses;
  final DateTime? updatedAt;

  /// Pourquoi rien ne se télécharge encore, en français, prêt à afficher.
  final String? waitingMessage;

  /// La sortie attendue d'un titre pas encore sorti.
  final DateTime? releaseDate;

  /// Le motif d'un refus.
  final String? note;

  /// Le nom du compte qui a demandé (liste de tous les comptes).
  final String? requester;

  factory MyRequest.fromJson(Map<String, dynamic> json) {
    final waiting = json['waiting'] is Map
        ? Map<String, dynamic>.from(json['waiting'] as Map)
        : null;
    return MyRequest(
      tmdbId: json['tmdbId'] as int? ?? 0,
      mediaType:
          json['mediaType'] == 'tv' ? RequestMediaType.tv : RequestMediaType.movie,
      title: json['title'] as String? ?? '',
      posterPath: json['posterPath'] as String?,
      seasons: (json['seasons'] as List<dynamic>? ?? const [])
          .whereType<int>()
          .toList(),
      status: _statusFrom(json['status'] as String?),
      requestedAt: DateTime.tryParse(json['requestedAt'] as String? ?? ''),
      progress: (json['progress'] as num?)?.toDouble(),
      requestIds: (json['requestIds'] as List<dynamic>? ?? const [])
          .whereType<int>()
          .toList(),
      seasonStatuses: (json['seasonStatuses'] as List<dynamic>? ?? const [])
          .map((e) =>
              MyRequestSeason.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      waitingMessage: _nonEmpty(waiting?['message']),
      releaseDate: DateTime.tryParse(waiting?['releaseDate'] as String? ?? ''),
      note: _nonEmpty(json['note']),
      requester: _nonEmpty(json['requester']),
    );
  }

  /// Une demande en attente d'une décision : celles que la modération propose.
  bool get awaitsDecision => status == MyRequestStatus.pending;

  /// Des saisons du lot n'en sont pas au même point : l'écran les détaille.
  bool get hasMixedSeasons =>
      seasonStatuses.length > 1 &&
      seasonStatuses.any((s) => s.status != seasonStatuses.first.status);

  String? get posterUrl => posterPath == null || posterPath!.isEmpty
      ? null
      : 'https://image.tmdb.org/t/p/w185$posterPath';

  /// La fiche de demande, rechargée depuis TMDB par son identifiant.
  RequestMediaItem toRequestItem() => RequestMediaItem(
        id: tmdbId,
        mediaType: mediaType,
        title: title,
        overview: '',
        posterPath: posterPath,
        backdropPath: null,
        releaseDate: null,
        rating: 0,
        status: switch (status) {
          MyRequestStatus.available => RequestMediaStatus.available,
          MyRequestStatus.partial => RequestMediaStatus.partial,
          MyRequestStatus.processing => RequestMediaStatus.processing,
          // Refusée : la fiche se rouvre comme un titre qu'on peut redemander.
          MyRequestStatus.declined => RequestMediaStatus.unknown,
          _ => RequestMediaStatus.pending,
        },
      );
}

String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

/// Ce que le compte peut faire chez le compagnon, par
/// `GET /api/requests/access` (ADR-0089).
class RequestAccess {
  const RequestAccess({
    required this.service,
    required this.linked,
    required this.canRequest,
    required this.canReadAll,
    required this.canModerate,
    required this.canDelete,
    this.canInteractiveSearch = false,
  });

  /// Ce que sait l'app d'un serveur d'avant cette route : demander, et
  /// lire ses propres demandes.
  static const basic = RequestAccess(
    service: '',
    linked: true,
    canRequest: true,
    canReadAll: false,
    canModerate: false,
    canDelete: false,
  );

  /// `mediahub` ou `onyxhub`.
  final String service;

  /// Un compte MediaHub porte le nom de ce compte Onyx.
  final bool linked;
  final bool canRequest;
  final bool canReadAll;
  final bool canModerate;
  final bool canDelete;

  /// Choisir soi-même la release d'une saison ou d'un épisode (ADR-0098).
  final bool canInteractiveSearch;

  factory RequestAccess.fromJson(Map<String, dynamic> json) {
    final can = json['can'] is Map
        ? Map<String, dynamic>.from(json['can'] as Map)
        : const <String, dynamic>{};
    return RequestAccess(
      service: json['service'] as String? ?? '',
      linked: json['linked'] as bool? ?? false,
      canRequest: can['request'] as bool? ?? false,
      canReadAll: can['readAllRequests'] as bool? ?? false,
      canModerate: can['moderate'] as bool? ?? false,
      canDelete: can['delete'] as bool? ?? false,
      canInteractiveSearch: can['interactiveSearch'] as bool? ?? false,
    );
  }
}

/// L'adresse qui ouvre MediaHub déjà connecté, par
/// `POST /api/integrations/mediahub/sso` (ADR-0090). Elle porte un code à
/// usage unique qui ne vaut que [expiresIn] secondes : elle s'ouvre tout de
/// suite et ne se garde pas.
class MediaHubTicket {
  const MediaHubTicket({required this.url, required this.expiresIn});

  final String url;
  final int expiresIn;

  factory MediaHubTicket.fromJson(Map<String, dynamic> json) => MediaHubTicket(
        url: json['url'] as String? ?? '',
        expiresIn: (json['expires_in'] as num?)?.toInt() ?? 0,
      );
}

/// Une décision sur un lot de demandes.
enum RequestModeration { approve, decline, delete }
