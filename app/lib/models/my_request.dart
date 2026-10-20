import 'media_request.dart';

/// Où en est une demande chez OnyxHub. `approved` n'existe pas dans
/// [RequestMediaStatus] : la demande est partie vers Radarr/Sonarr, rien n'est
/// encore en téléchargement.
enum MyRequestStatus { pending, approved, processing, partial, available }

MyRequestStatus _statusFrom(String? raw) => MyRequestStatus.values
    .firstWhere((s) => s.name == raw, orElse: () => MyRequestStatus.pending);

/// Une demande du compte, lue chez OnyxHub par `GET /api/requests/mine`
/// (ADR-0073). Une série demandée en plusieurs saisons d'un coup est un seul
/// lot.
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
  });

  final int tmdbId;
  final RequestMediaType mediaType;
  final String title;
  final String? posterPath;
  final List<int> seasons;
  final MyRequestStatus status;
  final DateTime? requestedAt;

  /// 0 à 100 pendant le téléchargement, null sinon.
  final double? progress;

  factory MyRequest.fromJson(Map<String, dynamic> json) => MyRequest(
        tmdbId: json['tmdbId'] as int? ?? 0,
        mediaType: json['mediaType'] == 'tv'
            ? RequestMediaType.tv
            : RequestMediaType.movie,
        title: json['title'] as String? ?? '',
        posterPath: json['posterPath'] as String?,
        seasons: (json['seasons'] as List<dynamic>? ?? const [])
            .whereType<int>()
            .toList(),
        status: _statusFrom(json['status'] as String?),
        requestedAt: DateTime.tryParse(json['requestedAt'] as String? ?? ''),
        progress: (json['progress'] as num?)?.toDouble(),
      );

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
          _ => RequestMediaStatus.pending,
        },
      );
}
