import 'media.dart';

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
    int readInt(dynamic value) {
      if (value == null) return 0;
      if (value is int) return value;
      if (value is double) return value.round();
      if (value is num) return value.toInt();
      return int.tryParse(value.toString()) ?? 0;
    }

    int introStart = readInt(json['intro_start']);
    int introEnd = readInt(json['intro_end']);
    int outroStart = readInt(json['outro_start']);
    int outroEnd = readInt(json['outro_end']);

    // Legacy nested format from GET /api/episodes/:id/timestamps
    final intro = json['intro'];
    if (intro is Map) {
      introStart = readInt(intro['start']);
      introEnd = readInt(intro['end']);
    }
    final outro = json['outro'];
    if (outro is Map) {
      outroStart = readInt(outro['start']);
      outroEnd = readInt(outro['end']);
    }

    return EpisodeTimestamps(
      introStart: introStart,
      introEnd: introEnd,
      outroStart: outroStart,
      outroEnd: outroEnd,
    );
  }

  bool get hasIntro => introEnd > 0 && introEnd > introStart;
  bool get hasOutro => outroEnd > 0 && outroEnd > outroStart;

  /// Rejects DB/chapter values that span most of the episode (bad detection).
  bool isPlausibleIntro({int? mediaDurationSeconds}) {
    if (!hasIntro) return false;
    final length = introEnd - introStart;
    if (length > 600) return false;
    if (mediaDurationSeconds != null && mediaDurationSeconds > 0) {
      if (introEnd > (mediaDurationSeconds * 0.85).round()) return false;
    }
    return true;
  }
}

/// The season that follows the one being watched, when the server does not
/// hold it. Absent from the payload whenever nothing can be offered — MediaHub
/// unreachable, or the show has no TMDB match.
class NextSeason {
  final int showId;
  final int showTmdbId;
  final String showTitle;
  final int number;
  final String name;
  final String? overview;
  final String? posterUrl;
  final int episodeCount;
  final String requestStatus;
  final bool canRequest;

  const NextSeason({
    required this.showId,
    required this.showTmdbId,
    required this.showTitle,
    required this.number,
    required this.name,
    this.overview,
    this.posterUrl,
    this.episodeCount = 0,
    required this.requestStatus,
    required this.canRequest,
  });

  /// True once a request has been sent but the season is not downloaded yet.
  bool get isRequested =>
      requestStatus == 'pending' || requestStatus == 'processing';

  factory NextSeason.fromJson(Map<String, dynamic> json) {
    return NextSeason(
      showId: json['show_id'] as int? ?? 0,
      showTmdbId: json['show_tmdb_id'] as int? ?? 0,
      showTitle: json['show_title'] as String? ?? '',
      number: json['number'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      overview: json['overview'] as String?,
      posterUrl: json['poster_url'] as String?,
      episodeCount: json['episode_count'] as int? ?? 0,
      requestStatus: json['request_status'] as String? ?? 'unavailable',
      canRequest: json['can_request'] as bool? ?? false,
    );
  }

  NextSeason copyWith({String? requestStatus, bool? canRequest}) {
    return NextSeason(
      showId: showId,
      showTmdbId: showTmdbId,
      showTitle: showTitle,
      number: number,
      name: name,
      overview: overview,
      posterUrl: posterUrl,
      episodeCount: episodeCount,
      requestStatus: requestStatus ?? this.requestStatus,
      canRequest: canRequest ?? this.canRequest,
    );
  }
}

/// The episode a season is still waiting for: TMDB lists it, the server does
/// not hold it. Nothing to play and nothing to request — a season is requested
/// whole — so the player only ever states when it lands.
class UpcomingEpisode {
  final int showId;
  final String showTitle;
  final int seasonNumber;
  final int number;
  final String name;
  final String? overview;
  final String? stillUrl;

  /// TMDB air date, `YYYY-MM-DD`. Empty for episodes not yet scheduled.
  final String? airDate;

  /// How many episodes the season holds in all, when TMDB knows.
  final int seasonEpisodes;

  const UpcomingEpisode({
    required this.showId,
    required this.showTitle,
    required this.seasonNumber,
    required this.number,
    required this.name,
    this.overview,
    this.stillUrl,
    this.airDate,
    this.seasonEpisodes = 0,
  });

  /// True while the episode has a date that has not come yet — the difference
  /// between "airs Friday" and "aired, but nobody imported it".
  bool get isUnaired {
    final raw = airDate;
    if (raw == null || raw.trim().isEmpty) return false;
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed == null) return false;
    final now = DateTime.now();
    return DateTime(parsed.year, parsed.month, parsed.day)
        .isAfter(DateTime(now.year, now.month, now.day));
  }

  factory UpcomingEpisode.fromJson(Map<String, dynamic> json) {
    return UpcomingEpisode(
      showId: json['show_id'] as int? ?? 0,
      showTitle: json['show_title'] as String? ?? '',
      seasonNumber: json['season_number'] as int? ?? 0,
      number: json['number'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      overview: json['overview'] as String?,
      stillUrl: json['still_url'] as String?,
      airDate: json['air_date'] as String?,
      seasonEpisodes: json['season_episodes'] as int? ?? 0,
    );
  }
}

class NextEpisodeResponse {
  final bool hasNext;
  final HomeMediaItem? episode;
  final NextSeason? nextSeason;
  final UpcomingEpisode? upcomingEpisode;

  NextEpisodeResponse({
    required this.hasNext,
    this.episode,
    this.nextSeason,
    this.upcomingEpisode,
  });

  factory NextEpisodeResponse.fromJson(Map<String, dynamic> json) {
    final episodeJson = json['episode'] as Map<String, dynamic>?;
    final seasonJson = json['next_season'] as Map<String, dynamic>?;
    final upcomingJson = json['upcoming_episode'] as Map<String, dynamic>?;
    return NextEpisodeResponse(
      hasNext: json['has_next'] as bool? ?? false,
      episode: episodeJson != null ? HomeMediaItem.fromJson(episodeJson) : null,
      nextSeason: seasonJson != null ? NextSeason.fromJson(seasonJson) : null,
      upcomingEpisode:
          upcomingJson != null ? UpcomingEpisode.fromJson(upcomingJson) : null,
    );
  }
}

class ShowResumeResponse {
  final bool hasEpisode;
  final int? seasonId;
  final HomeMediaItem? episode;

  ShowResumeResponse({
    required this.hasEpisode,
    this.seasonId,
    this.episode,
  });

  factory ShowResumeResponse.fromJson(Map<String, dynamic> json) {
    final episodeJson = json['episode'] as Map<String, dynamic>?;
    return ShowResumeResponse(
      hasEpisode: json['has_episode'] as bool? ?? false,
      seasonId: json['season_id'] as int?,
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
