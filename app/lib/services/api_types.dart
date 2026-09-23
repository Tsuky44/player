/// Les réponses du serveur qu'[ApiClient] décode pour l'administration :
/// sorties de api_client.dart, qui les exporte toujours.
library;

/// État du lien Emby d'un compte (GET/PUT/DELETE /api/me/emby).
class EmbyLinkStatus {
  final bool linked;
  final String url;
  final String username;
  final DateTime? lastSyncAt;
  final String lastError;

  const EmbyLinkStatus({
    required this.linked,
    this.url = '',
    this.username = '',
    this.lastSyncAt,
    this.lastError = '',
  });

  factory EmbyLinkStatus.fromJson(Map<String, dynamic> json) {
    final stamp = json['last_sync_at'] as String?;
    return EmbyLinkStatus(
      linked: json['linked'] as bool? ?? false,
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      lastSyncAt: stamp == null ? null : DateTime.tryParse(stamp)?.toLocal(),
      lastError: json['last_error'] as String? ?? '',
    );
  }
}

/// Public server settings from GET/PUT /api/settings (secrets are never cleartext).
class ServerSettings {
  final String mediaHubUrl;
  final bool mediaHubApiKeySet;
  final String? mediaHubApiKeyHint;
  final bool tmdbApiKeySet;
  final String? tmdbApiKeyHint;
  final String tmdbLanguage;
  final String moviesDir;
  final String seriesDir;
  final bool playbackLogsEnabled;

  /// Les mesures ont leur propre réglage : elles interrogent le moteur pendant
  /// toute la lecture, là où le journal ne coûte rien avant la fin.
  final bool playbackStatsEnabled;

  ServerSettings({
    required this.mediaHubUrl,
    required this.mediaHubApiKeySet,
    this.mediaHubApiKeyHint,
    required this.tmdbApiKeySet,
    this.tmdbApiKeyHint,
    required this.tmdbLanguage,
    required this.moviesDir,
    required this.seriesDir,
    required this.playbackLogsEnabled,
    required this.playbackStatsEnabled,
  });

  factory ServerSettings.fromJson(Map<String, dynamic> json) {
    return ServerSettings(
      mediaHubUrl: json['mediahub_url'] as String? ?? '',
      mediaHubApiKeySet: json['mediahub_api_key_set'] as bool? ?? false,
      mediaHubApiKeyHint: json['mediahub_api_key_hint'] as String?,
      tmdbApiKeySet: json['tmdb_api_key_set'] as bool? ?? false,
      tmdbApiKeyHint: json['tmdb_api_key_hint'] as String?,
      tmdbLanguage: json['tmdb_language'] as String? ?? 'fr-FR',
      moviesDir: json['movies_dir'] as String? ?? '',
      seriesDir: json['series_dir'] as String? ?? '',
      playbackLogsEnabled: json['playback_logs_enabled'] as bool? ?? true,
      playbackStatsEnabled: json['playback_stats_enabled'] as bool? ?? true,
    );
  }
}

/// Combined indexer / subtitle-extraction status from the server.
class IndexerStatus {
  final bool isScanning;
  final bool isBackfillingMetadata;
  final bool isRedetectingAll;
  final RedetectAllProgress redetectAll;
  final bool isExtractingSubtitles;
  final SubtitleExtractionStats subtitleExtraction;

  IndexerStatus({
    required this.isScanning,
    required this.isBackfillingMetadata,
    required this.isRedetectingAll,
    required this.redetectAll,
    required this.isExtractingSubtitles,
    required this.subtitleExtraction,
  });

  factory IndexerStatus.fromJson(Map<String, dynamic> json) {
    return IndexerStatus(
      isScanning: json["is_scanning"] as bool? ?? false,
      isBackfillingMetadata: json["is_backfilling_metadata"] as bool? ?? false,
      isRedetectingAll: json["is_redetecting_all"] as bool? ?? false,
      redetectAll: RedetectAllProgress.fromJson(
        json["redetect_all"] as Map<String, dynamic>? ?? {},
      ),
      isExtractingSubtitles: json["is_extracting_subtitles"] as bool? ?? false,
      subtitleExtraction: SubtitleExtractionStats.fromJson(
        json["subtitle_extraction"] as Map<String, dynamic>? ?? {},
      ),
    );
  }

  bool get isBusy =>
      isScanning ||
      isBackfillingMetadata ||
      isRedetectingAll ||
      isExtractingSubtitles;
}

class RedetectAllProgress {
  final int total;
  final int processed;
  final int updated;
  final int skipped;

  RedetectAllProgress({
    this.total = 0,
    this.processed = 0,
    this.updated = 0,
    this.skipped = 0,
  });

  factory RedetectAllProgress.fromJson(Map<String, dynamic> json) {
    return RedetectAllProgress(
      total: json["total"] as int? ?? 0,
      processed: json["processed"] as int? ?? 0,
      updated: json["updated"] as int? ?? 0,
      skipped: json["skipped"] as int? ?? 0,
    );
  }
}

class SubtitleExtractionStats {
  final int total;
  final int processed;
  final int succeeded;
  final int failed;
  final int tracks;

  SubtitleExtractionStats({
    this.total = 0,
    this.processed = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.tracks = 0,
  });

  factory SubtitleExtractionStats.fromJson(Map<String, dynamic> json) {
    return SubtitleExtractionStats(
      total: json["total"] as int? ?? 0,
      processed: json["processed"] as int? ?? 0,
      succeeded: json["succeeded"] as int? ?? 0,
      failed: json["failed"] as int? ?? 0,
      tracks: json["tracks"] as int? ?? 0,
    );
  }
}
