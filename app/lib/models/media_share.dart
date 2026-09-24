/// Un lien de partage public vers un film ou un épisode (ADR-0037), tel que
/// son créateur le voit. Miroir de `models.MediaShare` côté serveur.
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
  final String mediaType;

  /// Le film, ou la série pour un épisode ; [subtitle] porte alors
  /// « S01E02 · Titre de l'épisode ».
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

  const ShareLifetime(this.hours, this.label);

  /// La valeur envoyée au serveur ; 0 veut dire « sans échéance ».
  final int hours;
  final String label;
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
  });

  final bool needsPassword;
  final bool singleUse;
  final DateTime? expiresAt;
  final String mediaType;
  final String title;
  final String subtitle;
  final String? posterUrl;
  final int duration;

  factory SharedMediaInfo.fromJson(Map<String, dynamic> json) {
    final expires = json['expires_at'];
    final poster = json['poster_url'] as String?;
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
    );
  }
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
