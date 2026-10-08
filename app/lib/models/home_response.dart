import 'media.dart';

class HomeResponse {
  final List<HomeMediaItem> continueWatching;
  final List<Media> recentMovies;
  final List<Media> recentShows;
  final List<Media> discoveryMovies;
  final List<Media> discoveryShows;

  HomeResponse({
    required this.continueWatching,
    required this.recentMovies,
    required this.recentShows,
    this.discoveryMovies = const [],
    this.discoveryShows = const [],
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
    );
  }
}
