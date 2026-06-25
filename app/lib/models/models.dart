import 'dart:convert';

class User {
  final int id;
  final String username;

  User({
    required this.id,
    required this.username,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as int,
      username: json['username'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
    };
  }
}

enum MediaType { movie, show, season, episode }

MediaType parseMediaType(String typeStr) {
  switch (typeStr) {
    case 'movie':
      return MediaType.movie;
    case 'show':
      return MediaType.show;
    case 'season':
      return MediaType.season;
    case 'episode':
      return MediaType.episode;
    default:
      throw Exception('Unknown media type: $typeStr');
  }
}

String serializeMediaType(MediaType type) {
  return type.toString().split('.').last;
}

class Media {
  final int id;
  final MediaType type;
  final String title;
  final String? filePath;
  final int duration; // In seconds
  final int? parentId;
  final String? posterUrl;
  final String? overview;
  final String? releaseDate;
  final int? tmdbId;
  final DateTime createdAt;

  Media({
    required this.id,
    required this.type,
    required this.title,
    this.filePath,
    required this.duration,
    this.parentId,
    this.posterUrl,
    this.overview,
    this.releaseDate,
    this.tmdbId,
    required this.createdAt,
  });

  factory Media.fromJson(Map<String, dynamic> json) {
    return Media(
      id: json['id'] as int,
      type: parseMediaType(json['type'] as String),
      title: json['title'] as String,
      filePath: json['file_path'] as String?,
      duration: json['duration'] as int? ?? 0,
      parentId: json['parent_id'] as int?,
      posterUrl: json['poster_url'] as String?,
      overview: json['overview'] as String?,
      releaseDate: json['release_date'] as String?,
      tmdbId: json['tmdb_id'] as int?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': serializeMediaType(type),
      'title': title,
      'file_path': filePath,
      'duration': duration,
      'parent_id': parentId,
      'poster_url': posterUrl,
      'overview': overview,
      'release_date': releaseDate,
      'tmdb_id': tmdbId,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

class HomeMediaItem {
  final Media media;
  final int currentPositionSeconds;
  final int duration;
  final bool isFinished;
  final int introStart;
  final int introEnd;
  final int outroStart;
  final int outroEnd;

  HomeMediaItem({
    required this.media,
    required this.currentPositionSeconds,
    required this.duration,
    required this.isFinished,
    this.introStart = 0,
    this.introEnd = 0,
    this.outroStart = 0,
    this.outroEnd = 0,
  });

  factory HomeMediaItem.fromJson(Map<String, dynamic> json) {
    final rawFinished = json['is_finished'];
    bool finished = false;
    if (rawFinished is bool) {
      finished = rawFinished;
    } else if (rawFinished is int) {
      finished = rawFinished == 1;
    }

    return HomeMediaItem(
      media: Media.fromJson(json),
      currentPositionSeconds: json['current_position_seconds'] as int? ?? 0,
      duration: json['duration'] as int? ?? 0,
      isFinished: finished,
      introStart: json['intro_start'] as int? ?? 0,
      introEnd: json['intro_end'] as int? ?? 0,
      outroStart: json['outro_start'] as int? ?? 0,
      outroEnd: json['outro_end'] as int? ?? 0,
    );
  }

  double get percentWatched {
    if (duration <= 0) return 0.0;
    return (currentPositionSeconds / duration).clamp(0.0, 1.0);
  }
}

class EpisodeTimestamps {
  final int introStart;
  final int introEnd;
  final int outroStart;
  final int outroEnd;

  EpisodeTimestamps({
    required this.introStart,
    required this.introEnd,
    required this.outroStart,
    required this.outroEnd,
  });

  factory EpisodeTimestamps.fromJson(Map<String, dynamic> json) {
    return EpisodeTimestamps(
      introStart: json['intro_start'] as int? ?? 0,
      introEnd: json['intro_end'] as int? ?? 0,
      outroStart: json['outro_start'] as int? ?? 0,
      outroEnd: json['outro_end'] as int? ?? 0,
    );
  }

  bool get hasIntro => introEnd > 0 && introEnd > introStart;
  bool get hasOutro => outroEnd > 0 && outroEnd > outroStart;
}

class NextEpisodeResponse {
  final bool hasNext;
  final HomeMediaItem? episode;

  NextEpisodeResponse({
    required this.hasNext,
    this.episode,
  });

  factory NextEpisodeResponse.fromJson(Map<String, dynamic> json) {
    final episodeJson = json['episode'] as Map<String, dynamic>?;
    return NextEpisodeResponse(
      hasNext: json['has_next'] as bool? ?? false,
      episode: episodeJson != null ? HomeMediaItem.fromJson(episodeJson) : null,
    );
  }
}

class VideoChapter {
  final int id;
  final double startTime;
  final double endTime;
  final String title;

  VideoChapter({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.title,
  });

  factory VideoChapter.fromJson(Map<String, dynamic> json) {
    return VideoChapter(
      id: json['id'] as int? ?? 0,
      startTime: (json['start_time'] as num? ?? 0.0).toDouble(),
      endTime: (json['end_time'] as num? ?? 0.0).toDouble(),
      title: json['title'] as String? ?? '',
    );
  }
}

class HomeResponse {
  final List<HomeMediaItem> continueWatching;
  final List<Media> recentMovies;
  final List<Media> recentShows;

  HomeResponse({
    required this.continueWatching,
    required this.recentMovies,
    required this.recentShows,
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
    );
  }
}

/// Audio track metadata as probed from the original media file.
class MediaAudioTrack {
  final int index;
  final String codec;
  final String? language;
  final String? title;

  MediaAudioTrack({
    required this.index,
    required this.codec,
    this.language,
    this.title,
  });

  factory MediaAudioTrack.fromJson(Map<String, dynamic> json) {
    return MediaAudioTrack(
      index: json['index'] as int? ?? 0,
      codec: json['codec_name'] as String? ?? '',
      language: json['language'] as String?,
      title: json['title'] as String?,
    );
  }
}

/// Subtitle track metadata as probed from the original media file.
class MediaSubtitleTrack {
  final int index;
  final String codec;
  final String? language;
  final String? title;

  MediaSubtitleTrack({
    required this.index,
    required this.codec,
    this.language,
    this.title,
  });

  factory MediaSubtitleTrack.fromJson(Map<String, dynamic> json) {
    return MediaSubtitleTrack(
      index: json['index'] as int? ?? 0,
      codec: json['codec_name'] as String? ?? '',
      language: json['language'] as String?,
      title: json['title'] as String?,
    );
  }
}

/// Combined audio/subtitle tracks returned by the tracks API.
class MediaTracks {
  final List<MediaAudioTrack> audio;
  final List<MediaSubtitleTrack> subtitles;

  MediaTracks({
    required this.audio,
    required this.subtitles,
  });

  factory MediaTracks.fromJson(Map<String, dynamic> json) {
    return MediaTracks(
      audio: (json['audio'] as List<dynamic>?)
              ?.map((e) => MediaAudioTrack.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      subtitles: (json['subtitles'] as List<dynamic>?)
              ?.map((e) => MediaSubtitleTrack.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
