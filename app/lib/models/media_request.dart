enum RequestMediaType { movie, tv }

enum RequestMediaStatus { unknown, available, partial, pending, processing }

RequestMediaStatus _statusFromJson(String? value) {
  return RequestMediaStatus.values.firstWhere(
    (status) => status.name == value,
    orElse: () => RequestMediaStatus.unknown,
  );
}

class RequestMediaItem {
  final int id;
  final RequestMediaType mediaType;
  final String title;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? releaseDate;
  final double rating;
  final RequestMediaStatus status;

  const RequestMediaItem({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.overview,
    required this.posterPath,
    required this.backdropPath,
    required this.releaseDate,
    required this.rating,
    required this.status,
  });

  factory RequestMediaItem.fromJson(Map<String, dynamic> json) {
    return RequestMediaItem(
      id: json['id'] as int,
      mediaType: json['mediaType'] == 'tv'
          ? RequestMediaType.tv
          : RequestMediaType.movie,
      title: json['title'] as String? ?? 'Sans titre',
      overview: json['overview'] as String? ?? '',
      posterPath: json['posterPath'] as String?,
      backdropPath: json['backdropPath'] as String?,
      releaseDate: json['releaseDate'] as String?,
      rating: (json['rating'] as num? ?? 0).toDouble(),
      status: _statusFromJson(json['status'] as String?),
    );
  }

  String? get posterUrl =>
      posterPath == null || posterPath!.isEmpty
          ? null
          : 'https://image.tmdb.org/t/p/w500$posterPath';
  String? get backdropUrl =>
      backdropPath == null || backdropPath!.isEmpty
          ? null
          : 'https://image.tmdb.org/t/p/original$backdropPath';
  String? get year => releaseDate != null && releaseDate!.length >= 4
      ? releaseDate!.substring(0, 4)
      : null;
}

class RequestCatalogPage {
  final int page;
  final int totalPages;
  final List<RequestMediaItem> results;

  const RequestCatalogPage(
      {required this.page, required this.totalPages, required this.results});

  factory RequestCatalogPage.fromJson(Map<String, dynamic> json) {
    final results = json['results'] as List<dynamic>? ?? const [];
    return RequestCatalogPage(
      page: json['page'] as int? ?? 1,
      totalPages: json['totalPages'] as int? ?? 1,
      results: results
          .map(
              (item) => RequestMediaItem.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class RequestSeason {
  final int number;
  final String name;
  final int episodeCount;
  final String? posterPath;
  final RequestMediaStatus status;

  const RequestSeason({
    required this.number,
    required this.name,
    required this.episodeCount,
    required this.posterPath,
    required this.status,
  });

  factory RequestSeason.fromJson(Map<String, dynamic> json) {
    return RequestSeason(
      number: json['number'] as int,
      name: json['name'] as String? ?? '',
      episodeCount: json['episodeCount'] as int? ?? 0,
      posterPath: json['posterPath'] as String?,
      status: _statusFromJson(json['status'] as String?),
    );
  }

  String? get posterUrl =>
      posterPath == null || posterPath!.isEmpty
          ? null
          : 'https://image.tmdb.org/t/p/w300$posterPath';
}

class RequestCastMember {
  final int tmdbId;
  final String name;
  final String character;
  final String? profileUrl;

  const RequestCastMember({
    required this.tmdbId,
    required this.name,
    required this.character,
    required this.profileUrl,
  });

  factory RequestCastMember.fromJson(Map<String, dynamic> json) {
    return RequestCastMember(
      tmdbId: json['tmdbId'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      character: json['character'] as String? ?? '',
      profileUrl: json['profileUrl'] as String?,
    );
  }
}

class RequestMediaDetails extends RequestMediaItem {
  final int? runtime;
  final List<String> genres;
  final List<RequestSeason> seasons;
  final String? originalTitle;
  final String? tagline;
  final String? logoPath;
  final List<String> studios;
  final List<String> countries;
  final String? originalLanguage;
  final String? tmdbStatus;
  final String? director;
  final List<String> writers;
  final List<String> editors;
  final List<String> keywords;
  final String? trailerKey;
  final int? budget;
  final int? revenue;
  final List<RequestCastMember> cast;
  final int? numberOfSeasons;
  final int? numberOfEpisodes;
  final List<RequestMediaItem> recommendations;
  final List<RequestMediaItem> similar;

  const RequestMediaDetails({
    required super.id,
    required super.mediaType,
    required super.title,
    required super.overview,
    required super.posterPath,
    required super.backdropPath,
    required super.releaseDate,
    required super.rating,
    required super.status,
    required this.runtime,
    required this.genres,
    required this.seasons,
    this.originalTitle,
    this.tagline,
    this.logoPath,
    this.studios = const [],
    this.countries = const [],
    this.originalLanguage,
    this.tmdbStatus,
    this.director,
    this.writers = const [],
    this.editors = const [],
    this.keywords = const [],
    this.trailerKey,
    this.budget,
    this.revenue,
    this.cast = const [],
    this.numberOfSeasons,
    this.numberOfEpisodes,
    this.recommendations = const [],
    this.similar = const [],
  });

  factory RequestMediaDetails.fromJson(Map<String, dynamic> json) {
    final base = RequestMediaItem.fromJson(json);
    final seasons = json['seasons'] as List<dynamic>? ?? const [];
    final cast = json['cast'] as List<dynamic>? ?? const [];
    final recommendations = json['recommendations'] as List<dynamic>? ?? const [];
    final similar = json['similar'] as List<dynamic>? ?? const [];
    return RequestMediaDetails(
      id: base.id,
      mediaType: base.mediaType,
      title: base.title,
      overview: base.overview,
      posterPath: base.posterPath,
      backdropPath: base.backdropPath,
      releaseDate: base.releaseDate,
      rating: base.rating,
      status: base.status,
      runtime: json['runtime'] as int?,
      genres: (json['genres'] as List<dynamic>? ?? const []).cast<String>(),
      seasons: seasons
          .map((season) =>
              RequestSeason.fromJson(season as Map<String, dynamic>))
          .toList(),
      originalTitle: json['originalTitle'] as String?,
      tagline: json['tagline'] as String?,
      logoPath: json['logoPath'] as String?,
      studios: (json['studios'] as List<dynamic>? ?? const []).cast<String>(),
      countries:
          (json['countries'] as List<dynamic>? ?? const []).cast<String>(),
      originalLanguage: json['originalLanguage'] as String?,
      tmdbStatus: (json['tmdbStatus'] as String?) ?? (json['status'] as String?),
      director: json['director'] as String?,
      writers: (json['writers'] as List<dynamic>? ?? const []).cast<String>(),
      editors: (json['editors'] as List<dynamic>? ?? const []).cast<String>(),
      keywords: (json['keywords'] as List<dynamic>? ?? const []).cast<String>(),
      trailerKey: json['trailerKey'] as String?,
      budget: (json['budget'] as num?)?.toInt(),
      revenue: (json['revenue'] as num?)?.toInt(),
      cast: cast
          .map((member) =>
              RequestCastMember.fromJson(member as Map<String, dynamic>))
          .toList(),
      numberOfSeasons: json['numberOfSeasons'] as int?,
      numberOfEpisodes: json['numberOfEpisodes'] as int?,
      recommendations: recommendations
          .map((item) =>
              RequestMediaItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      similar: similar
          .map((item) =>
              RequestMediaItem.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  String? get logoUrl =>
      logoPath == null || logoPath!.isEmpty
          ? null
          : 'https://image.tmdb.org/t/p/original$logoPath';

  String get formattedRuntime {
    final minutes = runtime ?? 0;
    if (minutes <= 0) return '';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m.toString().padLeft(2, '0')}m';
  }
}
