import 'media.dart';
import 'media_library.dart';

class HomeResponse {
  final List<HomeMediaItem> continueWatching;
  final List<Media> recentMovies;
  final List<Media> recentShows;
  final List<Media> discoveryMovies;
  final List<Media> discoveryShows;

  /// Les derniers ajouts de chaque bibliothèque, sous son nom (ADR-0058).
  /// Vide pour un serveur d'avant les bibliothèques, qui n'a que
  /// [recentMovies] et [recentShows].
  final List<HomeLibraryRow> libraries;

  HomeResponse({
    required this.continueWatching,
    required this.recentMovies,
    required this.recentShows,
    this.discoveryMovies = const [],
    this.discoveryShows = const [],
    this.libraries = const [],
  });

  factory HomeResponse.fromJson(Map<String, dynamic> json) {
    return HomeResponse(
      continueWatching: (json['continue_watching'] as List<dynamic>?)
              ?.map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      recentMovies: (json['recent_movies'] as List<dynamic>?)
              ?.map((e) => Media.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      recentShows: (json['recent_shows'] as List<dynamic>?)
              ?.map((e) => Media.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      discoveryMovies: (json['discovery_movies'] as List<dynamic>?)
              ?.map((e) => Media.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      discoveryShows: (json['discovery_shows'] as List<dynamic>?)
              ?.map((e) => Media.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      libraries: (json['libraries'] as List<dynamic>?)
              ?.map((e) => HomeLibraryRow.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// La rangée d'une bibliothèque sur l'accueil : ce qui y a été ajouté en
/// dernier.
class HomeLibraryRow {
  const HomeLibraryRow({
    required this.id,
    required this.name,
    required this.kind,
    required this.items,
  });

  final int id;
  final String name;
  final LibraryKind kind;
  final List<Media> items;

  factory HomeLibraryRow.fromJson(Map<String, dynamic> json) {
    return HomeLibraryRow(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      kind: LibraryKind.parse(json['kind'] as String?),
      items: (json['items'] as List<dynamic>?)
              ?.map((e) => Media.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
