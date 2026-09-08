/// Administration rights carried by an account. Mirrors the server's
/// `models.Permissions`; hiding a section on these flags is comfort only, the
/// real guard is the server middleware.
class Permissions {
  final bool manageSettings;
  final bool manageLibrary;
  final bool manageUsers;
  final bool deleteMedia;
  final bool inviteUsers;
  final bool requestMedia;

  const Permissions({
    this.manageSettings = false,
    this.manageLibrary = false,
    this.manageUsers = false,
    this.deleteMedia = false,
    this.inviteUsers = false,
    this.requestMedia = false,
  });

  /// What the "Admin" shortcut ticks.
  static const all = Permissions(
    manageSettings: true,
    manageLibrary: true,
    manageUsers: true,
    deleteMedia: true,
    inviteUsers: true,
    requestMedia: true,
  );

  bool get isAdmin =>
      manageSettings &&
      manageLibrary &&
      manageUsers &&
      deleteMedia &&
      inviteUsers &&
      requestMedia;

  /// True when nothing at all is granted — used to label an empty template.
  bool get isEmpty =>
      !manageSettings &&
      !manageLibrary &&
      !manageUsers &&
      !deleteMedia &&
      !inviteUsers &&
      !requestMedia;

  factory Permissions.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const Permissions();
    bool flag(String key) => json[key] == true;
    return Permissions(
      manageSettings: flag('manage_settings'),
      manageLibrary: flag('manage_library'),
      manageUsers: flag('manage_users'),
      deleteMedia: flag('delete_media'),
      inviteUsers: flag('invite_users'),
      requestMedia: flag('request_media'),
    );
  }

  Map<String, dynamic> toJson() => {
        'manage_settings': manageSettings,
        'manage_library': manageLibrary,
        'manage_users': manageUsers,
        'delete_media': deleteMedia,
        'invite_users': inviteUsers,
        'request_media': requestMedia,
      };

  Permissions copyWith({
    bool? manageSettings,
    bool? manageLibrary,
    bool? manageUsers,
    bool? deleteMedia,
    bool? inviteUsers,
    bool? requestMedia,
  }) {
    return Permissions(
      manageSettings: manageSettings ?? this.manageSettings,
      manageLibrary: manageLibrary ?? this.manageLibrary,
      manageUsers: manageUsers ?? this.manageUsers,
      deleteMedia: deleteMedia ?? this.deleteMedia,
      inviteUsers: inviteUsers ?? this.inviteUsers,
      requestMedia: requestMedia ?? this.requestMedia,
    );
  }
}

class User {
  final int id;
  final String username;

  /// The first account created on a server. Asymmetric on purpose: the owner
  /// can demote any admin, nobody can demote the owner.
  final bool isOwner;
  final Permissions permissions;

  /// Rights the invitation links of this account will hand out. Set by an
  /// admin, never by the inviter — that is what keeps `inviteUsers` from being
  /// a path to admin.
  final Permissions inviteGrants;

  User({
    required this.id,
    required this.username,
    this.isOwner = false,
    this.permissions = const Permissions(),
    this.inviteGrants = const Permissions(),
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as int,
      username: json['username'] as String,
      isOwner: json['is_owner'] == true,
      permissions:
          Permissions.fromJson(json['permissions'] as Map<String, dynamic>?),
      inviteGrants:
          Permissions.fromJson(json['invite_grants'] as Map<String, dynamic>?),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'is_owner': isOwner,
      'permissions': permissions.toJson(),
      'invite_grants': inviteGrants.toJson(),
    };
  }
}

/// A single-use registration link.
class Invitation {
  final String token;
  final int inviterId;
  final String inviter;
  final Permissions grants;

  /// pending | used | revoked | expired — computed server-side.
  final String status;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final String usedBy;

  Invitation({
    required this.token,
    required this.inviterId,
    required this.inviter,
    required this.grants,
    required this.status,
    this.createdAt,
    this.expiresAt,
    this.usedBy = '',
  });

  bool get isPending => status == 'pending';

  factory Invitation.fromJson(Map<String, dynamic> json) {
    DateTime? parse(dynamic raw) =>
        raw is String && raw.isNotEmpty ? DateTime.tryParse(raw) : null;
    return Invitation(
      token: json['token'] as String? ?? '',
      inviterId: json['inviter_id'] as int? ?? 0,
      inviter: json['inviter'] as String? ?? '',
      grants: Permissions.fromJson(json['grants'] as Map<String, dynamic>?),
      status: json['status'] as String? ?? 'pending',
      createdAt: parse(json['created_at']),
      expiresAt: parse(json['expires_at']),
      usedBy: json['used_by'] as String? ?? '',
    );
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
    this.seasonNumber,
    this.episodeNumber,
    this.isAvailable = true,
    this.requestStatus,
    this.canRequest = false,
    this.episodeCount,
    required this.createdAt,
  });

  /// True once a request has been sent but the season is not downloaded yet.
  bool get isRequested =>
      requestStatus == 'pending' || requestStatus == 'processing';

  Media copyWith({
    bool? isAvailable,
    String? requestStatus,
    bool? canRequest,
  }) {
    return Media(
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

/// Resolves the title shown in player overlays (HUD + Player Studio).
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

/// Rich, Emby-style catalog details for a movie/show, returned by
/// GET /api/media/:id/details. Merges local library data with live TMDB
/// metadata (cast, genres, rating, backdrop, crew…).
class MediaDetails {
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

/// Maps an ISO 639 language code (2 or 3 letters) to a readable French name.
/// Falls back to the upper-cased code, or "Indéterminé" when unknown/empty.
String languageName(String? code) {
  if (code == null) return 'Indéterminé';
  final c = code.trim().toLowerCase();
  if (c.isEmpty || c == 'und') return 'Indéterminé';
  const map = {
    'fre': 'Français', 'fra': 'Français', 'fr': 'Français',
    'eng': 'Anglais', 'en': 'Anglais',
    'spa': 'Espagnol', 'es': 'Espagnol',
    'ger': 'Allemand', 'deu': 'Allemand', 'de': 'Allemand',
    'ita': 'Italien', 'it': 'Italien',
    'por': 'Portugais', 'pt': 'Portugais',
    'jpn': 'Japonais', 'ja': 'Japonais',
    'kor': 'Coréen', 'ko': 'Coréen',
    'chi': 'Chinois', 'zho': 'Chinois', 'zh': 'Chinois',
    'rus': 'Russe', 'ru': 'Russe',
    'ara': 'Arabe', 'ar': 'Arabe',
    'nld': 'Néerlandais', 'dut': 'Néerlandais', 'nl': 'Néerlandais',
    'pol': 'Polonais', 'pl': 'Polonais',
    'tur': 'Turc', 'tr': 'Turc',
    'hin': 'Hindi', 'hi': 'Hindi',
    'swe': 'Suédois', 'sv': 'Suédois',
    'nor': 'Norvégien', 'no': 'Norvégien',
    'dan': 'Danois', 'da': 'Danois',
    'fin': 'Finnois', 'fi': 'Finnois',
    'ces': 'Tchèque', 'cze': 'Tchèque', 'cs': 'Tchèque',
    'ukr': 'Ukrainien', 'uk': 'Ukrainien',
    'heb': 'Hébreu', 'he': 'Hébreu',
    'tha': 'Thaï', 'th': 'Thaï',
    'vie': 'Vietnamien', 'vi': 'Vietnamien',
  };
  return map[c] ?? code.toUpperCase();
}

String? _channelsLabel(int channels) {
  switch (channels) {
    case 1:
      return 'Mono';
    case 2:
      return 'Stéréo';
    case 6:
      return '5.1';
    case 8:
      return '7.1';
    default:
      return channels > 0 ? '${channels}ch' : null;
  }
}

/// Audio track metadata as probed from the original media file.
///
/// [typedIndex] is the position among audio streams only (FFmpeg "0:a:N") and
/// is the stable identifier used everywhere — for HLS rendition mapping and for
/// matching against the player's enumerated audio tracks in Direct Play.
class MediaAudioTrack {
  final int index;
  final int typedIndex;
  final String codec;
  final String? language;
  final String? title;
  final int channels;
  final bool isDefault;

  /// `atmos` or `dtsx`, empty for plain channel-based audio.
  ///
  /// Object-based audio is not a codec: Atmos rides inside E-AC-3 (as JOC) or
  /// TrueHD, and DTS:X inside DTS. The server reads it off the stream profile,
  /// which is the only place it is visible — so a track can say "EAC3" and be
  /// Atmos, and nothing but this field can tell them apart.
  final String spatialFormat;

  /// Whether the track is a bit-exact copy of its master (TrueHD, FLAC,
  /// DTS-HD MA, PCM).
  final bool lossless;

  MediaAudioTrack({
    required this.index,
    required this.typedIndex,
    required this.codec,
    this.language,
    this.title,
    this.channels = 0,
    this.isDefault = false,
    this.spatialFormat = '',
    this.lossless = false,
  });

  factory MediaAudioTrack.fromJson(Map<String, dynamic> json) {
    return MediaAudioTrack(
      index: json['index'] as int? ?? 0,
      typedIndex: json['typed_index'] as int? ?? 0,
      codec: json['codec_name'] as String? ?? '',
      language: json['language'] as String?,
      title: json['title'] as String?,
      channels: json['channels'] as int? ?? 0,
      isDefault: json['default'] as bool? ?? false,
      spatialFormat: json['spatial_format'] as String? ?? '',
      lossless: json['lossless'] as bool? ?? false,
    );
  }

  /// How the format is named to a person: "Dolby Atmos", "DTS:X", "Dolby
  /// Digital Plus", "DTS-HD MA".
  ///
  /// The spatial format wins when there is one, because it is what the track
  /// actually is — "EAC3" on an Atmos track is true and useless.
  String get formatLabel {
    switch (spatialFormat) {
      case 'atmos':
        return 'Dolby Atmos';
      case 'dtsx':
        return 'DTS:X';
    }
    switch (codec.toLowerCase()) {
      case 'eac3':
        return 'Dolby Digital+';
      case 'ac3':
        return 'Dolby Digital';
      case 'truehd':
        return 'Dolby TrueHD';
      case 'dts':
        return lossless ? 'DTS-HD MA' : 'DTS';
      case 'aac':
        return 'AAC';
      case 'flac':
        return 'FLAC';
      case 'opus':
        return 'Opus';
      default:
        return codec.toUpperCase();
    }
  }

  /// Emby-style readable name, e.g. "Français (Dolby Atmos 5.1)".
  String get displayName {
    final parts = <String>[];
    final t = title?.trim() ?? '';
    if (t.isNotEmpty) parts.add(t);
    if (codec.isNotEmpty) parts.add(formatLabel);
    final ch = _channelsLabel(channels);
    if (ch != null) parts.add(ch);
    final lang = languageName(language);
    return parts.isEmpty ? lang : '$lang (${parts.join(' ')})';
  }
}

/// An external subtitle language offered by the server (sidecar file or
/// OpenSubtitles download), addressed by its ISO-639 [lang] code.
///
/// MKV-embedded subtitle extraction has been abandoned: subtitles are always
/// clean external .vtt files served by the backend and injected into the player
/// as external tracks.
class MediaSubtitleTrack {
  final String lang;
  final String name;
  // True when a local file already exists (no download needed). When false the
  // server will fetch it on first request, which may take a moment.
  final bool ready;

  /// True while the server has only extracted the beginning of this track. It is
  /// usable immediately, but the complete version is still being produced and
  /// will need re-attaching once it lands.
  final bool partial;

  /// Position among the file's subtitle streams (the N in ffmpeg's 0:s:N), or
  /// -1 when unknown. This is what pairs an embedded track seen in Direct Play
  /// with its canonical entry here, so the client never has to derive a language
  /// code itself.
  final int typedIndex;

  /// True for a track that only subtitles foreign dialogue rather than the whole
  /// film. A file commonly ships both a full and a forced track for the same
  /// language, and picking the forced one by mistake looks like broken subtitles.
  final bool forced;

  /// True when the container flags this track as its preferred one.
  final bool isDefault;

  /// True for a bitmap track (PGS/VOBSUB). It has no .vtt: Direct Play renders it
  /// natively, while transcoding has to paint it into the picture — which makes
  /// it the one subtitle choice that costs a new HLS session.
  final bool image;

  MediaSubtitleTrack({
    required this.lang,
    required this.name,
    this.ready = false,
    this.partial = false,
    this.typedIndex = -1,
    this.forced = false,
    this.isDefault = false,
    this.image = false,
  });

  factory MediaSubtitleTrack.fromJson(Map<String, dynamic> json) {
    final lang = (json['lang'] as String?) ?? '';
    final name = (json['name'] as String?) ?? '';
    return MediaSubtitleTrack(
      lang: lang,
      name: name.isNotEmpty ? name : languageName(lang),
      ready: json['ready'] as bool? ?? false,
      partial: json['partial'] as bool? ?? false,
      typedIndex: (json['typed_index'] as num?)?.toInt() ?? -1,
      forced: json['forced'] as bool? ?? false,
      isDefault: json['default'] as bool? ?? false,
      image: json['image'] as bool? ?? false,
    );
  }

  String get displayName => name.isNotEmpty ? name : languageName(lang);
}

/// Primary video stream metadata (codec, pixel dimensions, dynamic range).
class MediaVideoTrack {
  final String codec;
  final int width;
  final int height;

  /// `hdr10`, `hlg`, `hdr10plus`, `dolbyvision`, or empty for SDR.
  ///
  /// Decided server-side rather than reconstructed here: what makes a stream
  /// HDR is a rule about colour transfer and side data, and a rule stated in
  /// two languages is a rule that will eventually disagree with itself.
  final String hdrFormat;

  /// Bits per sample, resolved by the server (8 when nothing said so).
  final int bitDepth;

  MediaVideoTrack({
    required this.codec,
    required this.width,
    required this.height,
    this.hdrFormat = '',
    this.bitDepth = 8,
  });

  factory MediaVideoTrack.fromJson(Map<String, dynamic> json) {
    return MediaVideoTrack(
      codec: json['codec_name'] as String? ?? '',
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      hdrFormat: json['hdr_format'] as String? ?? '',
      bitDepth: json['bit_depth'] as int? ?? 8,
    );
  }

  /// Emby-style resolution label, e.g. "4K", "1080p", "720p".
  String get resolutionLabel {
    // Cinemascope files often omit the black bars: width preserves the tier.
    if (width >= 7680 || height >= 4320) return '8K';
    if (width >= 3840 || height >= 2000) return '4K';
    if (width >= 1920 && height <= 1080 && height > 0) return '1080p';
    if (width >= 1280 && height <= 720 && height > 0) return '720p';
    if (height <= 0) return '';
    return '${height}p';
  }

  String get codecLabel {
    switch (codec.toLowerCase()) {
      case 'h264':
        return 'H.264';
      case 'hevc':
      case 'h265':
        return 'HEVC (H.265)';
      default:
        return codec.toUpperCase();
    }
  }

  /// True for anything that needs an HDR display to look right.
  bool get isHDR => hdrFormat.isNotEmpty;

  /// How the dynamic range is named to a person, or empty for SDR.
  String get hdrLabel {
    switch (hdrFormat) {
      case 'dolbyvision':
        return 'Dolby Vision';
      case 'hdr10plus':
        return 'HDR10+';
      case 'hdr10':
        return 'HDR10';
      case 'hlg':
        return 'HLG';
      default:
        return '';
    }
  }

  /// e.g. "4K HEVC Dolby Vision".
  String get displayName {
    final parts = <String>[
      if (resolutionLabel.isNotEmpty) resolutionLabel,
      if (codec.isNotEmpty) codec.toUpperCase(),
      if (hdrLabel.isNotEmpty) hdrLabel,
    ];
    return parts.join(' ');
  }
}

/// Combined video/audio/subtitle tracks returned by the tracks API.
class MediaTracks {
  final MediaVideoTrack? video;
  final List<MediaAudioTrack> audio;
  final List<MediaSubtitleTrack> subtitles;

  MediaTracks({
    this.video,
    required this.audio,
    required this.subtitles,
  });

  factory MediaTracks.fromJson(Map<String, dynamic> json) {
    return MediaTracks(
      video: json['video'] is Map<String, dynamic>
          ? MediaVideoTrack.fromJson(json['video'] as Map<String, dynamic>)
          : null,
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
