/// Ce que le tableau de bord montre du serveur : lectures en cours, historique,
/// statistiques, appareils connectés. Miroir de `server/handlers/activity.go`,
/// `devices.go` et `server_info.go`.
library;

DateTime _date(Object? raw) =>
    DateTime.tryParse(raw as String? ?? '')?.toLocal() ??
    DateTime.fromMillisecondsSinceEpoch(0);

int _int(Object? raw) => (raw as num?)?.toInt() ?? 0;

/// Null quand la valeur est absente, pour distinguer « pas mesuré » de « zéro
/// mesuré » — la différence entre une case vide et une lecture sans une seule
/// image.
double? _double(Object? raw) => (raw as num?)?.toDouble();

String _str(Object? raw) => raw as String? ?? '';

/// Comment l'image arrive à l'écran. Ce que « pourquoi le serveur rame »
/// demande en premier.
enum PlayMethod {
  direct('direct', 'Direct Play'),
  directStream('direct_stream', 'Direct Stream'),
  transcode('transcode', 'Transcodage'),
  local('local', 'Fichier téléchargé');

  const PlayMethod(this.wire, this.label);
  final String wire;
  final String label;

  static PlayMethod parse(String? raw) => PlayMethod.values.firstWhere(
        (m) => m.wire == raw,
        orElse: () => PlayMethod.direct,
      );
}

class NowPlayingSession {
  final String sessionId;
  final int userId;
  final String username;
  final String deviceName;
  final String client;
  final String address;
  final bool isLocal;
  final int mediaId;
  final String mediaType;
  final String title;
  final String subtitle;
  final String showTitle;
  final String posterUrl;
  final int positionSeconds;
  final int durationSeconds;
  final bool paused;
  final PlayMethod playMethod;
  final String quality;
  final DateTime startedAt;
  final int watchedSeconds;

  const NowPlayingSession({
    required this.sessionId,
    required this.userId,
    required this.username,
    required this.deviceName,
    required this.client,
    required this.address,
    required this.isLocal,
    required this.mediaId,
    required this.mediaType,
    required this.title,
    required this.subtitle,
    required this.showTitle,
    required this.posterUrl,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.paused,
    required this.playMethod,
    required this.quality,
    required this.startedAt,
    required this.watchedSeconds,
  });

  /// « Severance » pour un épisode, le titre pour un film.
  String get headline => showTitle.isNotEmpty ? showTitle : title;

  /// « S02E01 · Hello, Ms. Cobel » pour un épisode, rien pour un film.
  String get detail => showTitle.isEmpty
      ? ''
      : [if (subtitle.isNotEmpty) subtitle, title].join(' · ');

  double get progress => durationSeconds <= 0
      ? 0
      : (positionSeconds / durationSeconds).clamp(0.0, 1.0);

  factory NowPlayingSession.fromJson(Map<String, dynamic> json) =>
      NowPlayingSession(
        sessionId: _str(json['session_id']),
        userId: _int(json['user_id']),
        username: _str(json['username']),
        deviceName: _str(json['device_name']),
        client: _str(json['client']),
        address: _str(json['address']),
        isLocal: json['is_local'] as bool? ?? false,
        mediaId: _int(json['media_id']),
        mediaType: _str(json['media_type']),
        title: _str(json['title']),
        subtitle: _str(json['subtitle']),
        showTitle: _str(json['show_title']),
        posterUrl: _str(json['poster_url']),
        positionSeconds: _int(json['position_seconds']),
        durationSeconds: _int(json['duration_seconds']),
        paused: json['paused'] as bool? ?? false,
        playMethod: PlayMethod.parse(json['play_method'] as String?),
        quality: _str(json['quality']),
        startedAt: _date(json['started_at']),
        watchedSeconds: _int(json['watched_seconds']),
      );
}

class PlaybackHistoryEntry {
  final int id;
  final int userId;
  final String username;
  final int mediaId;
  final String mediaType;
  final String title;
  final String subtitle;
  final String showTitle;
  final String posterUrl;
  final String deviceName;
  final String client;
  final PlayMethod playMethod;
  final DateTime startedAt;
  final DateTime endedAt;
  final int watchedSeconds;
  final int positionSeconds;
  final int durationSeconds;

  const PlaybackHistoryEntry({
    required this.id,
    required this.userId,
    required this.username,
    required this.mediaId,
    required this.mediaType,
    required this.title,
    required this.subtitle,
    required this.showTitle,
    required this.posterUrl,
    required this.deviceName,
    required this.client,
    required this.playMethod,
    required this.startedAt,
    required this.endedAt,
    required this.watchedSeconds,
    required this.positionSeconds,
    required this.durationSeconds,
  });

  String get headline => showTitle.isNotEmpty ? showTitle : title;

  String get detail => showTitle.isEmpty
      ? ''
      : [if (subtitle.isNotEmpty) subtitle, title].join(' · ');

  factory PlaybackHistoryEntry.fromJson(Map<String, dynamic> json) =>
      PlaybackHistoryEntry(
        id: _int(json['id']),
        userId: _int(json['user_id']),
        username: _str(json['username']),
        mediaId: _int(json['media_id']),
        mediaType: _str(json['media_type']),
        title: _str(json['title']),
        subtitle: _str(json['subtitle']),
        showTitle: _str(json['show_title']),
        posterUrl: _str(json['poster_url']),
        deviceName: _str(json['device_name']),
        client: _str(json['client']),
        playMethod: PlayMethod.parse(json['play_method'] as String?),
        startedAt: _date(json['started_at']),
        endedAt: _date(json['ended_at']),
        watchedSeconds: _int(json['watched_seconds']),
        positionSeconds: _int(json['position_seconds']),
        durationSeconds: _int(json['duration_seconds']),
      );
}

class StatBucket {
  final String key;
  final String label;
  final String secondary;
  final String posterUrl;
  final String mediaType;
  final int plays;
  final int watchedSeconds;

  const StatBucket({
    required this.key,
    required this.label,
    required this.secondary,
    required this.posterUrl,
    required this.mediaType,
    required this.plays,
    required this.watchedSeconds,
  });

  factory StatBucket.fromJson(Map<String, dynamic> json) => StatBucket(
        key: _str(json['key']),
        label: _str(json['label']),
        secondary: _str(json['secondary']),
        posterUrl: _str(json['poster_url']),
        mediaType: _str(json['media_type']),
        plays: _int(json['plays']),
        watchedSeconds: _int(json['watched_seconds']),
      );
}

class DailyStat {
  final DateTime date;
  final int plays;
  final int watchedSeconds;

  const DailyStat(this.date, this.plays, this.watchedSeconds);

  factory DailyStat.fromJson(Map<String, dynamic> json) => DailyStat(
        DateTime.tryParse(_str(json['date'])) ?? DateTime(1970),
        _int(json['plays']),
        _int(json['watched_seconds']),
      );
}

class PlaybackStats {
  final int days;
  final int plays;
  final int watchedSeconds;
  final int activeUsers;
  final int movies;
  final int episodes;
  final List<DailyStat> daily;
  final List<int> hourOfDay;
  final List<StatBucket> topUsers;
  final List<StatBucket> topMedia;
  final List<StatBucket> clients;
  final List<StatBucket> playMethods;

  const PlaybackStats({
    required this.days,
    required this.plays,
    required this.watchedSeconds,
    required this.activeUsers,
    required this.movies,
    required this.episodes,
    required this.daily,
    required this.hourOfDay,
    required this.topUsers,
    required this.topMedia,
    required this.clients,
    required this.playMethods,
  });

  factory PlaybackStats.fromJson(Map<String, dynamic> json) {
    final totals = json['totals'] as Map<String, dynamic>? ?? const {};
    List<StatBucket> buckets(String key) => (json[key] as List? ?? const [])
        .map((e) => StatBucket.fromJson(e as Map<String, dynamic>))
        .toList();
    final hours = (json['hour_of_day'] as List? ?? const [])
        .map((e) => (e as num).toInt())
        .toList();
    return PlaybackStats(
      days: _int(json['days']),
      plays: _int(totals['plays']),
      watchedSeconds: _int(totals['watched_seconds']),
      activeUsers: _int(totals['active_users']),
      movies: _int(totals['movies']),
      episodes: _int(totals['episodes']),
      daily: (json['daily'] as List? ?? const [])
          .map((e) => DailyStat.fromJson(e as Map<String, dynamic>))
          .toList(),
      hourOfDay: hours.length == 24 ? hours : List.filled(24, 0),
      topUsers: buckets('top_users'),
      topMedia: buckets('top_media'),
      clients: buckets('clients'),
      playMethods: buckets('play_methods'),
    );
  }
}

/// Une session ouverte, c'est-à-dire un appareil connecté.
class ConnectedDevice {
  final int id;
  final int userId;
  final String username;
  final String deviceName;
  final String client;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final String address;
  final bool isLocal;
  final bool isCurrent;
  final String nowPlaying;

  const ConnectedDevice({
    required this.id,
    required this.userId,
    required this.username,
    required this.deviceName,
    required this.client,
    required this.createdAt,
    required this.lastSeenAt,
    required this.address,
    required this.isLocal,
    required this.isCurrent,
    required this.nowPlaying,
  });

  /// Une session ouverte avant que l'app ne s'annonce n'a pas de nom.
  String get displayName =>
      deviceName.isNotEmpty ? deviceName : 'Appareil sans nom';

  factory ConnectedDevice.fromJson(Map<String, dynamic> json) =>
      ConnectedDevice(
        id: _int(json['id']),
        userId: _int(json['user_id']),
        username: _str(json['username']),
        deviceName: _str(json['device_name']),
        client: _str(json['client']),
        createdAt: _date(json['created_at']),
        lastSeenAt: _date(json['last_seen_at']),
        address: _str(json['address']),
        isLocal: json['is_local'] as bool? ?? false,
        isCurrent: json['is_current'] as bool? ?? false,
        nowPlaying: _str(json['now_playing']),
      );
}

class ServerInfo {
  final DateTime startedAt;
  final int uptimeSeconds;
  final String goVersion;
  final String os;
  final String arch;
  final int cpus;
  final int memoryBytes;
  final int databaseBytes;
  final int transcodes;
  final int nowPlaying;
  final int users;
  final int activeDevices;
  final bool scanning;
  final int movies;
  final int shows;
  final int episodes;
  final int libraryBytes;
  final int libraryDurationSeconds;

  const ServerInfo({
    required this.startedAt,
    required this.uptimeSeconds,
    required this.goVersion,
    required this.os,
    required this.arch,
    required this.cpus,
    required this.memoryBytes,
    required this.databaseBytes,
    required this.transcodes,
    required this.nowPlaying,
    required this.users,
    required this.activeDevices,
    required this.scanning,
    required this.movies,
    required this.shows,
    required this.episodes,
    required this.libraryBytes,
    required this.libraryDurationSeconds,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) {
    final library = json['library'] as Map<String, dynamic>? ?? const {};
    return ServerInfo(
      startedAt: _date(json['started_at']),
      uptimeSeconds: _int(json['uptime_seconds']),
      goVersion: _str(json['go_version']),
      os: _str(json['os']),
      arch: _str(json['arch']),
      cpus: _int(json['cpus']),
      memoryBytes: _int(json['memory_bytes']),
      databaseBytes: _int(json['database_bytes']),
      transcodes: _int(json['transcodes']),
      nowPlaying: _int(json['now_playing']),
      users: _int(json['users']),
      activeDevices: _int(json['active_devices']),
      scanning: json['scanning'] as bool? ?? false,
      movies: _int(library['movies']),
      shows: _int(library['shows']),
      episodes: _int(library['episodes']),
      libraryBytes: _int(library['total_bytes']),
      libraryDurationSeconds: _int(library['duration_seconds']),
    );
  }
}

/// Une ligne du journal qu'un client a laissée derrière une lecture.
///
/// Miroir de `PlaybackLogLine` dans `server/handlers/playback_logs.go`. Le
/// niveau n'est pas deviné du texte : il est celui que le client a écrit.
class PlaybackLogLine {
  final DateTime at;
  final bool isError;
  final String message;

  const PlaybackLogLine({
    required this.at,
    required this.isError,
    required this.message,
  });

  factory PlaybackLogLine.fromJson(Map<String, dynamic> json) =>
      PlaybackLogLine(
        at: _date(json['at']),
        isError: _str(json['level']) == 'error',
        message: _str(json['message']),
      );

  /// `12:04:07.318 · message`, à l'heure de l'appareil qui lit — pas de celui
  /// qui a écrit. Les deux peuvent être à des fuseaux différents ; celui qui
  /// enquête compare ce journal à sa propre horloge.
  String format() {
    String two(int v) => v.toString().padLeft(2, '0');
    final local = at.toLocal();
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
        '.${local.millisecond.toString().padLeft(3, '0')} · $message';
  }
}

/// Ce qu'une lecture a mesuré d'elle-même, tel que l'historique le rend.
///
/// À ne pas confondre avec [PlaybackStats], qui agrège le serveur entier sur
/// trente jours. Celle-ci porte sur une séance et une seule.
///
/// Miroir de ce que `PlaybackStatsSummary` envoie, côté lecteur. Tous les
/// champs sont optionnels : les moteurs ne savent pas répondre aux mêmes
/// questions, et une lecture faite par un client plus ancien n'en rapporte
/// aucune. Une case vide se dessine comme une case vide — elle ne se remplit
/// pas d'un zéro qui se lirait comme une mesure.
class PlaybackSessionStats {
  const PlaybackSessionStats({
    this.sampledSeconds = 0,
    this.sampleCount = 0,
    this.averageFps,
    this.containerFps,
    this.averageBitrateBps,
    this.videoBitrateBps,
    this.audioBitrateBps,
    this.droppedFrames,
    this.renderedFrames,
    this.videoCodec,
    this.audioCodec,
    this.decoder,
    this.bufferingEvents = 0,
    this.bufferingSeconds = 0,
    this.startupMillis,
  });

  final double sampledSeconds;
  final int sampleCount;
  final double? averageFps;
  final double? containerFps;
  final double? averageBitrateBps;
  final double? videoBitrateBps;
  final double? audioBitrateBps;
  final int? droppedFrames;
  final int? renderedFrames;
  final String? videoCodec;
  final String? audioCodec;
  final String? decoder;
  final int bufferingEvents;
  final double bufferingSeconds;
  final int? startupMillis;

  bool get isEmpty => sampleCount == 0;

  /// La proportion d'images perdues, entre 0 et 1.
  double? get dropRatio {
    final dropped = droppedFrames;
    final rendered = renderedFrames;
    if (dropped == null || rendered == null) return null;
    final total = dropped + rendered;
    if (total <= 0) return null;
    return dropped / total;
  }

  /// Vrai quand le décodage s'est fait par le processeur.
  ///
  /// Le nom du décodeur est la seule source qui le dise : `no` côté mpv quand
  /// l'accélération n'a pas pris, et côté Android un `OMX.google.*` ou un
  /// `c2.android.*`, qui sont les décodeurs logiciels fournis avec le système.
  /// C'est l'explication la plus fréquente d'une lecture qui saccade sans
  /// jamais tomber en panne, et elle n'apparaissait nulle part.
  bool get looksSoftwareDecoded {
    final name = decoder?.toLowerCase();
    if (name == null || name.isEmpty) return false;
    return name == 'no' ||
        name.contains('omx.google') ||
        name.contains('c2.android') ||
        name.contains('ffmpeg') ||
        name.contains('software');
  }

  factory PlaybackSessionStats.fromJson(Map<String, dynamic> json) =>
      PlaybackSessionStats(
        sampledSeconds: _double(json['sampled_seconds']) ?? 0,
        sampleCount: _int(json['sample_count']),
        averageFps: _double(json['average_fps']),
        containerFps: _double(json['container_fps']),
        averageBitrateBps: _double(json['average_bitrate_bps']),
        videoBitrateBps: _double(json['video_bitrate_bps']),
        audioBitrateBps: _double(json['audio_bitrate_bps']),
        droppedFrames:
            json['dropped_frames'] == null ? null : _int(json['dropped_frames']),
        renderedFrames: json['rendered_frames'] == null
            ? null
            : _int(json['rendered_frames']),
        videoCodec: json['video_codec'] == null ? null : _str(json['video_codec']),
        audioCodec: json['audio_codec'] == null ? null : _str(json['audio_codec']),
        decoder: json['decoder'] == null ? null : _str(json['decoder']),
        bufferingEvents: _int(json['buffering_events']),
        bufferingSeconds: _double(json['buffering_seconds']) ?? 0,
        startupMillis:
            json['startup_ms'] == null ? null : _int(json['startup_ms']),
      );
}

/// Le journal d'une lecture passée.
class PlaybackLogs {
  final List<PlaybackLogLine> lines;

  /// Au moins une ligne est une erreur. Le serveur le lit des lignes, jamais du
  /// client : c'est ce qui décide qu'une lecture trop courte reste malgré tout
  /// dans l'historique.
  final bool hasError;

  /// Ce que la lecture a mesuré. Null quand elle n'a rien mesuré — un client
  /// plus ancien, ou un serveur où les mesures sont coupées.
  final PlaybackSessionStats? stats;

  const PlaybackLogs({required this.lines, required this.hasError, this.stats});

  static const empty = PlaybackLogs(lines: [], hasError: false);

  /// Vide quand il n'y a ni ligne ni mesure : l'un des deux suffit à rendre
  /// l'écran utile.
  bool get isEmpty => lines.isEmpty && (stats?.isEmpty ?? true);

  bool get hasLines => lines.isNotEmpty;

  factory PlaybackLogs.fromJson(Map<String, dynamic> json) => PlaybackLogs(
        lines: ((json['lines'] as List?) ?? const [])
            .map((e) => PlaybackLogLine.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        hasError: json['has_error'] as bool? ?? false,
        stats: json['stats'] is Map<String, dynamic>
            ? PlaybackSessionStats.fromJson(
                json['stats'] as Map<String, dynamic>)
            : null,
      );
}
