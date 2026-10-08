import 'catalog.dart';
import 'media.dart';

/// Rich catalog details for a movie/show, returned by
/// GET /api/media/:id/details. Merges local library data with live TMDB
/// metadata (cast, genres, rating, backdrop, crew…).
class MediaDetails {
  final List<MediaVersion> versions;
  final int id;
  final int? tmdbId;
  final MediaType type;
  final String title;
  final String? originalTitle;
  final String? tagline;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final String? logoUrl;
  final String? fileName;
  final String? localFolder;
  final String? localEpisodeFile;
  final String? releaseDate;
  final int runtime; // minutes (TMDB)
  final int duration; // seconds (local file)
  final String? status;
  final double voteAverage;
  final List<String> genres;
  final List<String> studios;
  final List<String> countries;
  final String? originalLanguage;
  final String? director;
  final List<String> writers;
  final List<CastMember> cast;
  final CollectionInfo? collection;
  final int numberOfSeasons;
  final int numberOfEpisodes;

  /// TMDB titles close to this one, tagged with a local id when the library
  /// already holds them. Drives the "Titres similaires" rail.
  final List<CatalogItem> similarTitles;

  MediaDetails({
    this.versions = const [],
    required this.id,
    this.tmdbId,
    required this.type,
    required this.title,
    this.originalTitle,
    this.tagline,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.logoUrl,
    this.fileName,
    this.localFolder,
    this.localEpisodeFile,
    this.releaseDate,
    this.runtime = 0,
    this.duration = 0,
    this.status,
    this.voteAverage = 0,
    this.genres = const [],
    this.studios = const [],
    this.countries = const [],
    this.originalLanguage,
    this.director,
    this.writers = const [],
    this.cast = const [],
    this.collection,
    this.numberOfSeasons = 0,
    this.numberOfEpisodes = 0,
    this.similarTitles = const [],
  });

  factory MediaDetails.fromJson(Map<String, dynamic> json) {
    List<String> stringList(dynamic value) {
      if (value is List) {
        return value.map((e) => e.toString()).toList();
      }
      return const [];
    }

    return MediaDetails(
      versions: MediaVersion.parseList(json['versions']),
      id: json['id'] as int,
      tmdbId: json['tmdb_id'] as int?,
      type: parseMediaType(json['type'] as String),
      title: json['title'] as String? ?? '',
      originalTitle: json['original_title'] as String?,
      tagline: json['tagline'] as String?,
      overview: json['overview'] as String?,
      posterUrl: json['poster_url'] as String?,
      backdropUrl: json['backdrop_url'] as String?,
      logoUrl: json['logo_url'] as String?,
      fileName: json['file_name'] as String?,
      localFolder: json['local_folder'] as String?,
      localEpisodeFile: json['local_episode_file'] as String?,
      releaseDate: json['release_date'] as String?,
      runtime: json['runtime'] as int? ?? 0,
      duration: json['duration'] as int? ?? 0,
      status: json['status'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0,
      genres: stringList(json['genres']),
      studios: stringList(json['studios']),
      countries: stringList(json['countries']),
      originalLanguage: json['original_language'] as String?,
      director: json['director'] as String?,
      writers: stringList(json['writers']),
      cast: (json['cast'] as List<dynamic>?)
              ?.map((e) => CastMember.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      collection: json['collection'] != null
          ? CollectionInfo.fromJson(json['collection'] as Map<String, dynamic>)
          : null,
      numberOfSeasons: json['number_of_seasons'] as int? ?? 0,
      numberOfEpisodes: json['number_of_episodes'] as int? ?? 0,
      similarTitles: (json['similar_titles'] as List<dynamic>?)
              ?.map((e) => CatalogItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  /// Runtime in seconds preferring TMDB minutes, falling back to local duration.
  int get effectiveDurationSeconds {
    if (runtime > 0) return runtime * 60;
    return duration;
  }

  bool get hasRating => voteAverage > 0;
}
