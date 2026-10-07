import 'models.dart';
import '../l10n/tr.dart';

/// Dit si [mediaType] (`media_type` côté serveur) est une saison ou une série
/// entière : un lien qui ouvre plusieurs épisodes, jamais à usage unique.
bool isSharedCollectionType(String mediaType) =>
    mediaType == 'season' || mediaType == 'show';

/// Un lien de partage public vers un film, un épisode, une saison ou une série
/// (ADR-0037), tel que son créateur le voit. Miroir de `models.MediaShare`
/// côté serveur.
class MediaShare {
  const MediaShare({
    required this.id,
    required this.mediaId,
    required this.title,
    required this.status,
    this.mediaType = '',
    this.subtitle = '',
    this.posterUrl,
    this.hasPassword = false,
    this.singleUse = false,
    this.expiresAt,
    this.claimed = false,
    this.consumedAt,
    this.views = 0,
    this.createdAt,
    this.code,
  });

  final int id;
  final int mediaId;

  /// `movie`, `episode`, `season` ou `show`.
  final String mediaType;

  /// Le film, ou la série ; [subtitle] porte alors « S01E02 · Titre de
  /// l'épisode », « Saison 2 » ou « Série entière ».
  final String title;
  final String subtitle;
  final String? posterUrl;
  final bool hasPassword;
  final bool singleUse;

  /// Nul pour un lien sans échéance.
  final DateTime? expiresAt;

  /// Un navigateur a réservé ce lien à usage unique.
  final bool claimed;
  final DateTime? consumedAt;
  final int views;

  /// `active`, `expired` ou `watched`, décidé par le serveur.
  final String status;
  final DateTime? createdAt;

  /// Le code du lien. Le serveur ne le rend qu'à la création : il n'en garde
  /// que l'empreinte, et ne pourra plus le redonner.
  final String? code;

  bool get isActive => status == 'active';

  factory MediaShare.fromJson(Map<String, dynamic> json) {
    DateTime? parse(dynamic raw) => raw is String && raw.isNotEmpty
        ? DateTime.tryParse(raw)?.toLocal()
        : null;
    final code = json['code'] as String?;
    return MediaShare(
      id: json['id'] as int? ?? 0,
      mediaId: json['media_id'] as int? ?? 0,
      mediaType: json['media_type'] as String? ?? '',
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      posterUrl: json['poster_url'] as String?,
      hasPassword: json['has_password'] == true,
      singleUse: json['single_use'] == true,
      expiresAt: parse(json['expires_at']),
      claimed: json['claimed'] == true,
      consumedAt: parse(json['consumed_at']),
      views: json['views'] as int? ?? 0,
      status: json['status'] as String? ?? 'active',
      createdAt: parse(json['created_at']),
      code: code == null || code.isEmpty ? null : code,
    );
  }
}

/// Les durées de validité qu'un lien peut avoir, dans l'ordre où elles sont
/// proposées. La liste est fermée côté serveur (`sharelinks.Lifetimes`).
enum ShareLifetime {
  day(24, '24 heures'),
  week(24 * 7, '7 jours'),
  month(24 * 30, '30 jours'),
  forever(0, 'Sans limite');

  const ShareLifetime(this.hours, this._label);

  /// La valeur envoyée au serveur ; 0 veut dire « sans échéance ».
  final int hours;
  final String _label;

  String get label => tr(_label);
}

/// Ce qu'un visiteur sans compte apprend d'un lien (POST /api/shared/info et
/// /open). Tant qu'un mot de passe est exigé, [title] et les suivants sont
/// vides : le serveur ne dit pas quel média le lien ouvre.
class SharedMediaInfo {
  const SharedMediaInfo({
    this.needsPassword = false,
    this.singleUse = false,
    this.expiresAt,
    this.mediaType = '',
    this.title = '',
    this.subtitle = '',
    this.posterUrl,
    this.duration = 0,
    this.episodes = const [],
    this.details,
  });

  final bool needsPassword;
  final bool singleUse;
  final DateTime? expiresAt;
  final String mediaType;
  final String title;
  final String subtitle;
  final String? posterUrl;
  final int duration;

  /// Les épisodes que le lien d'une saison ou d'une série permet de lire,
  /// dans l'ordre de diffusion. Vide pour un film ou un épisode.
  final List<SharedEpisode> episodes;

  /// La fiche de la série d'une saison ou d'une série partagée : synopsis,
  /// fond, logo, genres, distribution. Nulle pour un film ou un épisode.
  final MediaDetails? details;

  /// Le lien ouvre une saison ou une série : le visiteur choisit un épisode.
  bool get isCollection => isSharedCollectionType(mediaType);

  factory SharedMediaInfo.fromJson(Map<String, dynamic> json) {
    final expires = json['expires_at'];
    final poster = json['poster_url'] as String?;
    final details = json['details'];
    return SharedMediaInfo(
      needsPassword: json['needs_password'] == true,
      singleUse: json['single_use'] == true,
      expiresAt:
          expires is String ? DateTime.tryParse(expires)?.toLocal() : null,
      mediaType: json['media_type'] as String? ?? '',
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      posterUrl: poster == null || poster.isEmpty ? null : poster,
      duration: json['duration'] as int? ?? 0,
      episodes: (json['episodes'] as List<dynamic>? ?? const [])
          .map((e) => SharedEpisode.fromJson(e as Map<String, dynamic>))
          .toList(),
      details: details is Map<String, dynamic>
          ? MediaDetails.fromJson(details)
          : null,
    );
  }
}

/// Un épisode du lien d'une saison ou d'une série. Miroir de
/// `models.SharedEpisode` côté serveur.
class SharedEpisode {
  const SharedEpisode({
    required this.id,
    this.seasonNumber = 0,
    this.episodeNumber = 0,
    this.title = '',
    this.duration = 0,
    this.seasonId = 0,
    this.overview,
    this.stillUrl,
    this.releaseDate,
    this.introStart = 0,
    this.introEnd = 0,
    this.outroStart = 0,
    this.outroEnd = 0,
  });

  final int id;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final int duration;

  /// La saison de l'épisode ; 0 quand le serveur, plus ancien, ne la dit pas.
  final int seasonId;
  final String? overview;
  final String? stillUrl;
  final String? releaseDate;

  /// Les bornes du générique, en secondes ; 0 quand elles ne sont pas connues.
  final int introStart;
  final int introEnd;
  final int outroStart;
  final int outroEnd;

  factory SharedEpisode.fromJson(Map<String, dynamic> json) => SharedEpisode(
        id: json['id'] as int? ?? 0,
        seasonNumber: json['season_number'] as int? ?? 0,
        episodeNumber: json['episode_number'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        duration: json['duration'] as int? ?? 0,
        seasonId: json['season_id'] as int? ?? 0,
        overview: _nonEmpty(json['overview']),
        stillUrl: _nonEmpty(json['still_url']),
        releaseDate: _nonEmpty(json['release_date']),
        introStart: json['intro_start'] as int? ?? 0,
        introEnd: json['intro_end'] as int? ?? 0,
        outroStart: json['outro_start'] as int? ?? 0,
        outroEnd: json['outro_end'] as int? ?? 0,
      );

  static String? _nonEmpty(dynamic raw) =>
      raw is String && raw.isNotEmpty ? raw : null;
}

/// Un refus du serveur sur un lien : [message] est la phrase à montrer telle
/// quelle au visiteur, [status] le code HTTP (404 inconnu, 410 expiré ou vu,
/// 409 ouvert ailleurs, 401 mauvais mot de passe, 0 serveur injoignable).
class SharedLinkException implements Exception {
  const SharedLinkException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'SharedLinkException($status, $message)';
}
