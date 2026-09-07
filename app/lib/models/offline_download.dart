import 'models.dart';

/// Où en est un téléchargement, du point de vue de l'utilisateur.
///
/// Il n'y a délibérément pas d'état « en pause automatique » distinct : une
/// coupure réseau remet l'entrée en [queued], parce que c'est exactement ce que
/// la file doit faire quand la connexion revient. Seul un geste de
/// l'utilisateur produit [paused].
enum DownloadStatus { queued, downloading, paused, completed, failed }

/// Une piste de sous-titres rapatriée à côté du fichier.
///
/// Les pistes internes au conteneur voyagent avec lui et n'ont rien à faire
/// ici ; ce sont les WebVTT que le serveur extrait, ceux que le lecteur injecte
/// par leur contenu, qui doivent être copiés pour exister hors ligne.
class OfflineSubtitle {
  final String lang;
  final String name;

  /// Nom du fichier dans le dossier du média (pas un chemin absolu : le
  /// conteneur d'application se déplace d'une version d'app à l'autre sur iOS
  /// comme sur macOS, et un chemin gravé dans le manifeste ne survivrait pas).
  final String fileName;

  const OfflineSubtitle({
    required this.lang,
    required this.name,
    required this.fileName,
  });

  factory OfflineSubtitle.fromJson(Map<String, dynamic> json) => OfflineSubtitle(
        lang: json['lang'] as String? ?? '',
        name: json['name'] as String? ?? '',
        fileName: json['file_name'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'lang': lang,
        'name': name,
        'file_name': fileName,
      };
}

/// Un média rapatrié sur l'appareil, et tout ce qu'il faut savoir de lui sans
/// serveur : de quoi l'afficher dans une liste, le lire, et se souvenir de ce
/// qui en a été vu en attendant de pouvoir le dire au serveur.
///
/// L'objet est immuable ; [copyWith] produit la version suivante et le store
/// réécrit le manifeste.
class OfflineDownload {
  final int mediaId;
  final MediaType type;

  /// Titre de l'épisode ou du film.
  final String title;

  /// Série d'appartenance, pour les épisodes. C'est ce qui permet de grouper
  /// l'écran des téléchargements sans rien demander au serveur.
  final String? showTitle;
  final int? showId;
  final int? seasonNumber;
  final int? episodeNumber;

  final String? overview;
  final String? releaseDate;

  /// Serveur d'où le média a été rapatrié, normalisé.
  ///
  /// C'est ce qui rattache l'entrée à son compte : le playeur à appliquer hors
  /// ligne ([OfflineChrome]) est celui de ce serveur-là, même si l'app a été
  /// pointée ailleurs depuis.
  final String serverUrl;

  /// URL distante de l'affiche, telle que l'API l'a donnée. Conservée pour le
  /// jour où la vignette locale manque (échec du rapatriement de l'image).
  final String? posterUrl;
  final String? showPosterUrl;

  final int durationSeconds;
  final int introStart;
  final int introEnd;
  final int outroStart;
  final int outroEnd;

  /// Nom du fichier vidéo dans le dossier du média.
  final String fileName;

  /// Vignette locale, si elle a pu être rapatriée.
  final String? posterFileName;

  final int bytesReceived;

  /// Taille annoncée par le serveur, ou 0 tant qu'on ne l'a pas.
  final int bytesTotal;

  final DownloadStatus status;
  final String? error;

  final DateTime addedAt;
  final DateTime? completedAt;

  final List<OfflineSubtitle> subtitles;

  /// Réponse brute de `/api/media/:id/tracks`, mise de côté telle quelle : le
  /// lecteur la reparse hors ligne pour peupler ses menus audio et sous-titres.
  final Map<String, dynamic>? tracks;

  // ---- Avancement local ----

  /// Position atteinte sur cet appareil. Fait autorité tant que [needsSync].
  final int positionSeconds;
  final bool isFinished;

  /// Quand l'avancement local a été touché. Envoyé au serveur lors de la
  /// resynchronisation pour qu'il puisse refuser une lecture plus ancienne que
  /// ce qu'il a déjà.
  final DateTime? progressUpdatedAt;

  /// L'avancement local n'a pas encore été accepté par le serveur.
  final bool needsSync;

  const OfflineDownload({
    required this.mediaId,
    required this.type,
    required this.title,
    required this.fileName,
    required this.addedAt,
    this.showTitle,
    this.showId,
    this.seasonNumber,
    this.episodeNumber,
    this.overview,
    this.releaseDate,
    this.serverUrl = '',
    this.posterUrl,
    this.showPosterUrl,
    this.durationSeconds = 0,
    this.introStart = 0,
    this.introEnd = 0,
    this.outroStart = 0,
    this.outroEnd = 0,
    this.posterFileName,
    this.bytesReceived = 0,
    this.bytesTotal = 0,
    this.status = DownloadStatus.queued,
    this.error,
    this.completedAt,
    this.subtitles = const [],
    this.tracks,
    this.positionSeconds = 0,
    this.isFinished = false,
    this.progressUpdatedAt,
    this.needsSync = false,
  });

  bool get isCompleted => status == DownloadStatus.completed;
  bool get isActive =>
      status == DownloadStatus.downloading || status == DownloadStatus.queued;

  /// Fraction téléchargée, ou null tant que la taille totale est inconnue —
  /// une barre indéterminée dit la vérité, une barre à zéro non.
  double? get progress {
    if (isCompleted) return 1;
    if (bytesTotal <= 0) return null;
    return (bytesReceived / bytesTotal).clamp(0.0, 1.0);
  }

  double get watchedFraction {
    if (durationSeconds <= 0) return 0;
    return (positionSeconds / durationSeconds).clamp(0.0, 1.0);
  }

  /// Étiquette « S2E5 » quand les deux numéros sont connus.
  String? get episodeCode {
    final s = seasonNumber;
    final e = episodeNumber;
    if (s == null || e == null || s <= 0 || e <= 0) return null;
    return 'S${s}E${e.toString().padLeft(2, '0')}';
  }

  /// Ce qui s'affiche en tête de ligne : la série pour un épisode, le titre
  /// pour un film.
  String get groupTitle =>
      (showTitle != null && showTitle!.isNotEmpty) ? showTitle! : title;

  /// Sous quel identifiant chercher la fiche rapatriée avec ce média.
  ///
  /// Un épisode renvoie à sa série — la fiche décrit la série, et les vingt
  /// épisodes d'une saison la partagent. Un film est sa propre fiche. Les
  /// identifiants venant tous de la même table côté serveur, les deux cas
  /// cohabitent sans risque de collision.
  int? get infoId {
    if (type == MediaType.episode) {
      return (showId != null && showId! > 0) ? showId : null;
    }
    return mediaId;
  }

  OfflineDownload copyWith({
    String? title,
    int? durationSeconds,
    String? posterFileName,
    int? bytesReceived,
    int? bytesTotal,
    DownloadStatus? status,
    Object? error = _unset,
    DateTime? completedAt,
    List<OfflineSubtitle>? subtitles,
    Map<String, dynamic>? tracks,
    int? positionSeconds,
    bool? isFinished,
    DateTime? progressUpdatedAt,
    bool? needsSync,
    String? fileName,
    String? serverUrl,
  }) {
    return OfflineDownload(
      mediaId: mediaId,
      type: type,
      title: title ?? this.title,
      fileName: fileName ?? this.fileName,
      addedAt: addedAt,
      showTitle: showTitle,
      showId: showId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      overview: overview,
      releaseDate: releaseDate,
      serverUrl: serverUrl ?? this.serverUrl,
      posterUrl: posterUrl,
      showPosterUrl: showPosterUrl,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      introStart: introStart,
      introEnd: introEnd,
      outroStart: outroStart,
      outroEnd: outroEnd,
      posterFileName: posterFileName ?? this.posterFileName,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      status: status ?? this.status,
      error: error == _unset ? this.error : error as String?,
      completedAt: completedAt ?? this.completedAt,
      subtitles: subtitles ?? this.subtitles,
      tracks: tracks ?? this.tracks,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      isFinished: isFinished ?? this.isFinished,
      progressUpdatedAt: progressUpdatedAt ?? this.progressUpdatedAt,
      needsSync: needsSync ?? this.needsSync,
    );
  }

  /// Reconstruit l'objet que le reste de l'app manipule — le lecteur, les
  /// tuiles d'épisode — à partir de ce qui a été mis de côté au téléchargement.
  HomeMediaItem toHomeMediaItem() {
    return HomeMediaItem(
      media: Media(
        id: mediaId,
        type: type,
        title: title,
        duration: durationSeconds,
        posterUrl: posterUrl,
        overview: overview,
        releaseDate: releaseDate,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        createdAt: addedAt,
      ),
      currentPositionSeconds: positionSeconds,
      duration: durationSeconds,
      isFinished: isFinished,
      introStart: introStart,
      introEnd: introEnd,
      outroStart: outroStart,
      outroEnd: outroEnd,
      showTitle: showTitle,
      showPosterUrl: showPosterUrl,
      showId: showId,
      updatedAt: progressUpdatedAt,
    );
  }

  factory OfflineDownload.fromJson(Map<String, dynamic> json) {
    return OfflineDownload(
      mediaId: json['media_id'] as int,
      type: parseMediaType(json['type'] as String? ?? 'episode'),
      title: json['title'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      addedAt: DateTime.tryParse(json['added_at'] as String? ?? '') ??
          DateTime.now(),
      showTitle: json['show_title'] as String?,
      showId: json['show_id'] as int?,
      seasonNumber: json['season_number'] as int?,
      episodeNumber: json['episode_number'] as int?,
      overview: json['overview'] as String?,
      releaseDate: json['release_date'] as String?,
      serverUrl: json['server_url'] as String? ?? '',
      posterUrl: json['poster_url'] as String?,
      showPosterUrl: json['show_poster_url'] as String?,
      durationSeconds: json['duration'] as int? ?? 0,
      introStart: json['intro_start'] as int? ?? 0,
      introEnd: json['intro_end'] as int? ?? 0,
      outroStart: json['outro_start'] as int? ?? 0,
      outroEnd: json['outro_end'] as int? ?? 0,
      posterFileName: json['poster_file_name'] as String?,
      bytesReceived: json['bytes_received'] as int? ?? 0,
      bytesTotal: json['bytes_total'] as int? ?? 0,
      status: _statusFromName(json['status'] as String?),
      error: json['error'] as String?,
      completedAt: DateTime.tryParse(json['completed_at'] as String? ?? ''),
      subtitles: (json['subtitles'] as List?)
              ?.map((e) => OfflineSubtitle.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      tracks: json['tracks'] as Map<String, dynamic>?,
      positionSeconds: json['position_seconds'] as int? ?? 0,
      isFinished: json['is_finished'] == true,
      progressUpdatedAt:
          DateTime.tryParse(json['progress_updated_at'] as String? ?? ''),
      needsSync: json['needs_sync'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'media_id': mediaId,
        'type': serializeMediaType(type),
        'title': title,
        'file_name': fileName,
        'added_at': addedAt.toIso8601String(),
        if (showTitle != null) 'show_title': showTitle,
        if (showId != null) 'show_id': showId,
        if (seasonNumber != null) 'season_number': seasonNumber,
        if (episodeNumber != null) 'episode_number': episodeNumber,
        if (overview != null) 'overview': overview,
        if (releaseDate != null) 'release_date': releaseDate,
        if (serverUrl.isNotEmpty) 'server_url': serverUrl,
        if (posterUrl != null) 'poster_url': posterUrl,
        if (showPosterUrl != null) 'show_poster_url': showPosterUrl,
        'duration': durationSeconds,
        'intro_start': introStart,
        'intro_end': introEnd,
        'outro_start': outroStart,
        'outro_end': outroEnd,
        if (posterFileName != null) 'poster_file_name': posterFileName,
        'bytes_received': bytesReceived,
        'bytes_total': bytesTotal,
        'status': status.name,
        if (error != null) 'error': error,
        if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
        'subtitles': subtitles.map((s) => s.toJson()).toList(),
        if (tracks != null) 'tracks': tracks,
        'position_seconds': positionSeconds,
        'is_finished': isFinished,
        if (progressUpdatedAt != null)
          'progress_updated_at': progressUpdatedAt!.toIso8601String(),
        'needs_sync': needsSync,
      };

  static DownloadStatus _statusFromName(String? name) {
    for (final s in DownloadStatus.values) {
      if (s.name == name) return s;
    }
    return DownloadStatus.queued;
  }
}

/// Sentinelle de [OfflineDownload.copyWith] : distingue « ne touche pas à
/// `error` » de « remets-le à null ».
const Object _unset = Object();
