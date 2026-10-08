import 'media.dart';

/// A single actor entry for the cast row on detail pages.
class CastMember {
  final int? tmdbId;
  final String name;
  final String? character;
  final String? profileUrl;

  CastMember({
    this.tmdbId,
    required this.name,
    this.character,
    this.profileUrl,
  });

  factory CastMember.fromJson(Map<String, dynamic> json) {
    return CastMember(
      tmdbId: json['tmdb_id'] as int?,
      name: json['name'] as String? ?? '',
      character: json['character'] as String?,
      profileUrl: json['profile_url'] as String?,
    );
  }
}

/// A lightweight movie/show reference used in filmographies and collections.
/// [localId] is set (> 0) when the title exists in the library.
class CatalogItem {
  final int tmdbId;
  final int? localId;
  final String title;
  final String? posterUrl;
  final String? backdropUrl;
  final String? year;
  final MediaType mediaType;
  final String? character;

  /// TMDB vote average, 0 when the server did not provide one.
  final double rating;

  CatalogItem({
    required this.tmdbId,
    this.localId,
    required this.title,
    this.posterUrl,
    this.backdropUrl,
    this.year,
    required this.mediaType,
    this.character,
    this.rating = 0,
  });

  bool get isOwned => (localId ?? 0) > 0;

  factory CatalogItem.fromJson(Map<String, dynamic> json) {
    final typeStr = json['media_type'] as String? ?? 'movie';
    return CatalogItem(
      tmdbId: json['tmdb_id'] as int? ?? 0,
      localId: json['local_id'] as int?,
      title: json['title'] as String? ?? '',
      posterUrl: json['poster_url'] as String?,
      backdropUrl: json['backdrop_url'] as String?,
      year: json['year'] as String?,
      mediaType: typeStr == 'show' ? MediaType.show : MediaType.movie,
      character: json['character'] as String?,
      rating: (json['rating'] as num? ?? 0).toDouble(),
    );
  }

  /// Builds a local [Media] handle to open the detail screen (owned titles).
  Media toLocalMedia() {
    return Media(
      id: localId ?? 0,
      type: mediaType,
      title: title,
      duration: 0,
      posterUrl: posterUrl,
      releaseDate: year,
      tmdbId: tmdbId,
      createdAt: DateTime.now(),
    );
  }
}

/// A TMDB search result offered in the manual "fix metadata" picker.
class TmdbCandidate {
  final int tmdbId;
  final String title;
  final String? year;
  final String? overview;
  final String? posterUrl;
  final MediaType mediaType;

  TmdbCandidate({
    required this.tmdbId,
    required this.title,
    this.year,
    this.overview,
    this.posterUrl,
    required this.mediaType,
  });

  factory TmdbCandidate.fromJson(Map<String, dynamic> json) {
    return TmdbCandidate(
      tmdbId: json['tmdb_id'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      year: json['year'] as String?,
      overview: json['overview'] as String?,
      posterUrl: json['poster_url'] as String?,
      mediaType:
          (json['media_type'] as String?) == 'show' ? MediaType.show : MediaType.movie,
    );
  }
}

/// The compact saga reference embedded in a movie's details.
class CollectionInfo {
  final int id;
  final String name;
  final String? backdropUrl;
  final String? posterUrl;

  CollectionInfo({
    required this.id,
    required this.name,
    this.backdropUrl,
    this.posterUrl,
  });

  factory CollectionInfo.fromJson(Map<String, dynamic> json) {
    return CollectionInfo(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      backdropUrl: json['backdrop_url'] as String?,
      posterUrl: json['poster_url'] as String?,
    );
  }
}

/// The full saga payload with all its films.
class CollectionDetails {
  final int id;
  final String name;
  final String? overview;
  final String? backdropUrl;
  final List<CatalogItem> parts;

  CollectionDetails({
    required this.id,
    required this.name,
    this.overview,
    this.backdropUrl,
    this.parts = const [],
  });

  factory CollectionDetails.fromJson(Map<String, dynamic> json) {
    return CollectionDetails(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      overview: json['overview'] as String?,
      backdropUrl: json['backdrop_url'] as String?,
      parts: (json['parts'] as List<dynamic>?)
              ?.map((e) => CatalogItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

/// An actor/crew profile with filmography.
class PersonDetails {
  final int id;
  final String name;
  final String? profileUrl;
  final String? biography;
  final String? birthday;
  final String? deathday;
  final String? placeOfBirth;
  final String? knownForDepartment;
  final String? backdropUrl;
  final List<CatalogItem> filmography;

  PersonDetails({
    required this.id,
    required this.name,
    this.profileUrl,
    this.biography,
    this.birthday,
    this.deathday,
    this.placeOfBirth,
    this.knownForDepartment,
    this.backdropUrl,
    this.filmography = const [],
  });

  factory PersonDetails.fromJson(Map<String, dynamic> json) {
    return PersonDetails(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      profileUrl: json['profile_url'] as String?,
      biography: json['biography'] as String?,
      birthday: json['birthday'] as String?,
      deathday: json['deathday'] as String?,
      placeOfBirth: json['place_of_birth'] as String?,
      knownForDepartment: json['known_for_department'] as String?,
      backdropUrl: json['backdrop_url'] as String?,
      filmography: (json['filmography'] as List<dynamic>?)
              ?.map((e) => CatalogItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}
