import 'media_request.dart';

/// Les demandes faites depuis le dernier passage, lues chez OnyxHub par
/// `GET /api/requests/feed` (ADR-0077). Réservé à `manage_settings`.
class RequestFeed {
  const RequestFeed({required this.cursor, required this.requests});

  /// À renvoyer au passage suivant (`?after=`).
  final int cursor;

  /// Les plus anciennes d'abord. Jamais celles du compte qui demande.
  final List<RequestFeedEntry> requests;

  factory RequestFeed.fromJson(Map<String, dynamic> json) => RequestFeed(
        cursor: (json['cursor'] as num?)?.toInt() ?? 0,
        requests: (json['requests'] as List<dynamic>? ?? const [])
            .map((e) =>
                RequestFeedEntry.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// Une demande : un film, ou les saisons d'une série demandées d'un geste.
class RequestFeedEntry {
  const RequestFeedEntry({
    required this.id,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.posterPath,
    required this.seasons,
    required this.requester,
    required this.requestedAt,
  });

  /// Stable chez OnyxHub : l'identifiant de la notification en dérive.
  final int id;
  final RequestMediaType mediaType;
  final int tmdbId;
  final String title;
  final String? posterPath;

  /// Vide pour un film.
  final List<int> seasons;

  /// Le nom du compte Onyx qui a demandé.
  final String requester;
  final DateTime? requestedAt;

  factory RequestFeedEntry.fromJson(Map<String, dynamic> json) =>
      RequestFeedEntry(
        id: (json['id'] as num?)?.toInt() ?? 0,
        mediaType: json['mediaType'] == 'tv'
            ? RequestMediaType.tv
            : RequestMediaType.movie,
        tmdbId: (json['tmdbId'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        posterPath: json['posterPath'] as String?,
        seasons: (json['seasons'] as List<dynamic>? ?? const [])
            .whereType<int>()
            .toList(),
        requester: json['requester'] as String? ?? '',
        requestedAt: DateTime.tryParse(json['requestedAt'] as String? ?? ''),
      );

  /// L'affiche de la notification. w342 : assez pour l'image dépliée
  /// d'Android, sans peser plus de quelques dizaines de Ko sur le forfait.
  String? get posterUrl => posterPath == null || posterPath!.isEmpty
      ? null
      : 'https://image.tmdb.org/t/p/w342$posterPath';
}
