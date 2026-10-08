import '../l10n/tr.dart';

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
  final List<MediaVersion> versions;
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
  final int? seasonNumber;
  final int? episodeNumber;
  final bool isAvailable;

  /// MediaHub status of a season the server does not hold: `unknown`,
  /// `pending`, `processing`, `partial`, `available`, or `unavailable` when
  /// MediaHub itself could not be consulted. Null for anything else.
  final String? requestStatus;

  /// Whether a request can be sent for this season. Decided by the server —
  /// never recomputed from [requestStatus], so an unreachable MediaHub can
  /// never be mistaken for "free to request".
  final bool canRequest;

  /// Episode count announced by TMDB for a missing season.
  final int? episodeCount;

  /// Séries uniquement — décompte d'avancement renseigné par `/api/shows`.
  ///
  /// [availableEpisodeCount] ne compte que les épisodes réellement présents sur
  /// le serveur : « vu en entier » veut dire « tout ce que le serveur a », pas
  /// « tout ce que TMDB annonce ».
  final int? availableEpisodeCount;

  /// Épisodes disponibles terminés par l'utilisateur courant.
  final int? watchedEpisodeCount;

  /// Épisodes commencés mais pas terminés.
  final int? startedEpisodeCount;

  final DateTime createdAt;

  Media({
    this.versions = const [],
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
    this.seasonNumber,
    this.episodeNumber,
    this.isAvailable = true,
    this.requestStatus,
    this.canRequest = false,
    this.episodeCount,
    this.availableEpisodeCount,
    this.watchedEpisodeCount,
    this.startedEpisodeCount,
    required this.createdAt,
  });

  /// True once a request has been sent but the season is not downloaded yet.
  bool get isRequested =>
      requestStatus == 'pending' || requestStatus == 'processing';

  /// Série vue en entier : tous les épisodes que le serveur possède sont
  /// terminés. Une série sans épisode indexé n'est jamais « vue ».
  bool get isFullyWatched =>
      (availableEpisodeCount ?? 0) > 0 &&
      (watchedEpisodeCount ?? 0) >= availableEpisodeCount!;

  /// Série entamée : au moins un épisode vu ou commencé, mais pas tous.
  bool get isPartiallyWatched =>
      !isFullyWatched &&
      ((watchedEpisodeCount ?? 0) > 0 || (startedEpisodeCount ?? 0) > 0);

  /// Épisodes disponibles qu'il reste à voir.
  int get remainingEpisodeCount {
    final remaining = (availableEpisodeCount ?? 0) - (watchedEpisodeCount ?? 0);
    return remaining > 0 ? remaining : 0;
  }

  Media copyWith({
    bool? isAvailable,
    String? requestStatus,
    bool? canRequest,
  }) {
    return Media(
      versions: versions,
      id: id,
      type: type,
      title: title,
      filePath: filePath,
      duration: duration,
      parentId: parentId,
      posterUrl: posterUrl,
      overview: overview,
      releaseDate: releaseDate,
      tmdbId: tmdbId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      isAvailable: isAvailable ?? this.isAvailable,
      requestStatus: requestStatus ?? this.requestStatus,
      canRequest: canRequest ?? this.canRequest,
      episodeCount: episodeCount,
      availableEpisodeCount: availableEpisodeCount,
      watchedEpisodeCount: watchedEpisodeCount,
      startedEpisodeCount: startedEpisodeCount,
      createdAt: createdAt,
    );
  }

  factory Media.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as int? ?? 0;
    final filePath = json['file_path'] as String?;
    final type = parseMediaType(json['type'] as String);
    final rawAvailable = json['is_available'];
    final bool isAvailable;
    if (rawAvailable is bool) {
      isAvailable = rawAvailable;
    } else if (type == MediaType.episode) {
      // Legacy payloads without is_available: present iff a file is indexed.
      isAvailable = id > 0 && filePath != null && filePath.isNotEmpty;
    } else {
      // Movies / shows / local seasons default to available.
      isAvailable = true;
    }

    return Media(
      versions: MediaVersion.parseList(json['versions']),
      id: id,
      type: type,
      title: json['title'] as String? ?? '',
      filePath: filePath,
      duration: json['duration'] as int? ?? 0,
      parentId: json['parent_id'] as int?,
      posterUrl: json['poster_url'] as String?,
      overview: json['overview'] as String?,
      releaseDate: json['release_date'] as String?,
      tmdbId: json['tmdb_id'] as int?,
      seasonNumber: json['season_number'] as int?,
      episodeNumber: json['episode_number'] as int?,
      isAvailable: isAvailable,
      requestStatus: json['request_status'] as String?,
      canRequest: json['can_request'] as bool? ?? false,
      episodeCount: json['episode_count'] as int?,
      availableEpisodeCount: json['available_episode_count'] as int?,
      watchedEpisodeCount: json['watched_episode_count'] as int?,
      startedEpisodeCount: json['started_episode_count'] as int?,
      createdAt: _parseOptionalDateTime(json['created_at']) ?? DateTime.now(),
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
      'season_number': seasonNumber,
      'episode_number': episodeNumber,
      'is_available': isAvailable,
      'request_status': requestStatus,
      'can_request': canRequest,
      'episode_count': episodeCount,
      'available_episode_count': availableEpisodeCount,
      'watched_episode_count': watchedEpisodeCount,
      'started_episode_count': startedEpisodeCount,
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// Compact TV code such as [S01E02], or null when not an episode.
  String? get seasonEpisodeCode {
    if (type != MediaType.episode) return null;

    final season = effectiveSeasonNumber;
    final episode = effectiveEpisodeNumber;
    if ((season == null || season <= 0) && (episode == null || episode <= 0)) {
      return null;
    }

    final buffer = StringBuffer();
    if (season != null && season > 0) {
      buffer.write('S${season.toString().padLeft(2, '0')}');
    }
    if (episode != null && episode > 0) {
      buffer.write('E${episode.toString().padLeft(2, '0')}');
    }
    return buffer.isEmpty ? null : buffer.toString();
  }

  /// Season number from metadata, with fallbacks parsed from titles/paths (S01E02, Saison 1…).
  int? get effectiveSeasonNumber {
    if (seasonNumber != null && seasonNumber! > 0) return seasonNumber;
    if (filePath != null && filePath!.isNotEmpty) {
      final fromPath = _tvNumberFromTitle(filePath!, season: true);
      if (fromPath != null) return fromPath;
    }
    return _tvNumberFromTitle(title, season: true);
  }

  /// Episode number from metadata, with fallbacks parsed from titles/paths (S01E02…).
  int? get effectiveEpisodeNumber {
    if (episodeNumber != null && episodeNumber! > 0) return episodeNumber;
    if (filePath != null && filePath!.isNotEmpty) {
      final fromPath = _tvNumberFromTitle(filePath!, season: false);
      if (fromPath != null) return fromPath;
    }
    return _tvNumberFromTitle(title, season: false);
  }

  String? seasonEpisodeCodeWith({int? seasonOverride}) {
    if (type != MediaType.episode) return null;

    final season = (seasonOverride != null && seasonOverride > 0)
        ? seasonOverride
        : effectiveSeasonNumber;
    final episode = effectiveEpisodeNumber;
    if ((season == null || season <= 0) && (episode == null || episode <= 0)) {
      return null;
    }

    final buffer = StringBuffer();
    if (season != null && season > 0) {
      buffer.write('S${season.toString().padLeft(2, '0')}');
    }
    if (episode != null && episode > 0) {
      buffer.write('E${episode.toString().padLeft(2, '0')}');
    }
    return buffer.isEmpty ? null : buffer.toString();
  }
}

int? _tvNumberFromTitle(String title, {required bool season}) {
  final sxxExx =
      RegExp(r's(\d+)e(\d+)', caseSensitive: false).firstMatch(title);
  if (sxxExx != null) {
    final group = season ? sxxExx.group(1) : sxxExx.group(2);
    return group != null ? int.tryParse(group) : null;
  }

  if (season) {
    final saison = RegExp(r'(?:saison|season)\s*(\d+)', caseSensitive: false)
        .firstMatch(title);
    if (saison != null) return int.tryParse(saison.group(1)!);
  }

  return null;
}

DateTime? _parseOptionalDateTime(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
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
  final String? showTitle;
  final String? showPosterUrl;
  final int? showId;
  final String? episodeTitle;
  final DateTime? updatedAt;

  /// Séries uniquement : l'épisode à reprendre vient tout juste de sortir et
  /// n'a pas encore été vu. Renseigné par le serveur pour « À reprendre ».
  final bool hasNewEpisode;

  HomeMediaItem({
    required this.media,
    required this.currentPositionSeconds,
    required this.duration,
    required this.isFinished,
    this.updatedAt,
    this.hasNewEpisode = false,
    this.introStart = 0,
    this.introEnd = 0,
    this.outroStart = 0,
    this.outroEnd = 0,
    this.showTitle,
    this.showPosterUrl,
    this.showId,
    this.episodeTitle,
  });

  /// Whether this item can be played from the local library.
  bool get isAvailable => media.isAvailable;

  factory HomeMediaItem.fromJson(Map<String, dynamic> json) {
    final rawFinished = json['is_finished'];
    bool finished = false;
    if (rawFinished is bool) {
      finished = rawFinished;
    } else if (rawFinished is int) {
      finished = rawFinished == 1;
    }

    final media = Media.fromJson(json);

    return HomeMediaItem(
      media: media,
      currentPositionSeconds: json['current_position_seconds'] as int? ?? 0,
      duration: json['duration'] as int? ?? 0,
      isFinished: finished,
      updatedAt: _parseOptionalDateTime(json['updated_at']) ??
          _parseOptionalDateTime(json['created_at']),
      introStart: json['intro_start'] as int? ?? 0,
      introEnd: json['intro_end'] as int? ?? 0,
      outroStart: json['outro_start'] as int? ?? 0,
      outroEnd: json['outro_end'] as int? ?? 0,
      showTitle: json['show_title'] as String?,
      showPosterUrl: json['show_poster_url'] as String?,
      showId: json['show_id'] as int?,
      episodeTitle: json['episode_title'] as String?,
      hasNewEpisode: json['has_new_episode'] == true,
    );
  }

  /// Builds a [Media] handle for navigating to movie/show detail screens.
  Media? get detailMedia {
    if (media.type == MediaType.movie) return media;
    if (media.type == MediaType.episode && showId != null && showId! > 0) {
      return Media(
        id: showId!,
        type: MediaType.show,
        title: displayTitle,
        posterUrl: showPosterUrl,
        duration: 0,
        createdAt: updatedAt ?? media.createdAt,
      );
    }
    return null;
  }

  /// Title shown in lists (show name for episodes in continue watching).
  String get displayTitle =>
      showTitle?.isNotEmpty == true ? showTitle! : media.title;

  /// Title shown in the player overlay (show name + SxxExx for TV episodes).
  String playerTitle({int? seasonNumber}) {
    if (media.type != MediaType.episode) return displayTitle;

    final code = media.seasonEpisodeCodeWith(seasonOverride: seasonNumber);
    if (code == null) return displayTitle;

    return '$displayTitle – $code';
  }

  /// Poster shown in continue watching (show artwork for TV episodes).
  String? get displayPosterUrl =>
      showPosterUrl?.isNotEmpty == true ? showPosterUrl : media.posterUrl;

  int get effectiveDuration {
    if (duration > 0) return duration;
    return media.duration;
  }

  double get percentWatched {
    final total = effectiveDuration;
    if (total <= 0) return 0.0;
    return (currentPositionSeconds / total).clamp(0.0, 1.0);
  }

  String? get continueWatchingSubtitle {
    if (media.type != MediaType.episode) return null;
    final parts = <String>[];
    final season = media.effectiveSeasonNumber;
    final episode = media.effectiveEpisodeNumber;
    if (season != null && season > 0) {
      parts.add('S$season');
    }
    if (episode != null && episode > 0) {
      parts.add('E$episode');
    }
    final epTitle = episodeTitle ?? media.title;
    if (epTitle.isNotEmpty) {
      parts.add(epTitle);
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  HomeMediaItem copyWith({
    int? currentPositionSeconds,
    int? duration,
    bool? isFinished,
    DateTime? updatedAt,
  }) {
    return HomeMediaItem(
      media: media,
      currentPositionSeconds: currentPositionSeconds ?? this.currentPositionSeconds,
      duration: duration ?? this.duration,
      isFinished: isFinished ?? this.isFinished,
      updatedAt: updatedAt ?? this.updatedAt,
      introStart: introStart,
      introEnd: introEnd,
      outroStart: outroStart,
      outroEnd: outroEnd,
      showTitle: showTitle,
      showPosterUrl: showPosterUrl,
      showId: showId,
      episodeTitle: episodeTitle,
      hasNewEpisode: hasNewEpisode,
    );
  }
}

/// Resolves the title shown in player overlays (HUD).
String playerMediaTitle(Object? media, {int? seasonNumber}) {
  if (media is HomeMediaItem) {
    return media.playerTitle(seasonNumber: seasonNumber);
  }
  if (media is Media) {
    if (media.type != MediaType.episode) return media.title;
    final code = media.seasonEpisodeCodeWith(seasonOverride: seasonNumber);
    if (code == null) return media.title;
    return '${media.title} – $code';
  }
  return '';
}

/// Un fichier de ce média parmi plusieurs (montage, qualité).
class MediaVersion {
  final HomeMediaItem item;
  final String label;

  MediaVersion({required this.item, required this.label});

  static List<MediaVersion> parseList(dynamic value) => value is List
      ? value.map((entry) {
          final json = entry as Map<String, dynamic>;
          return MediaVersion(
            item: HomeMediaItem.fromJson(json),
            label: json['label'] as String? ?? tr('Version'),
          );
        }).toList()
      : const [];
}
