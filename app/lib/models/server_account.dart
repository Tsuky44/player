/// Un serveur Onyx et le compte qui va avec, tel que l'app le retient.
///
/// Il n'existe pas d'identité fédérée entre serveurs : chacun tient sa propre
/// table `users`, et « mon compte » veut dire une identité par serveur. Ce que
/// l'app peut faire, c'est en garder plusieurs sous la main et n'en activer
/// qu'une à la fois — voir ADR-0013.
class ServerAccount {
  /// Clé de stockage du jeton et du profil de ce compte. Dérivée de l'adresse
  /// et de l'identifiant, donc stable d'un lancement à l'autre : c'est ce qui
  /// permet de réenregistrer le même compte sans en fabriquer un doublon.
  final String id;

  /// Adresse normalisée du serveur (schéma explicite, sans barre finale).
  final String url;

  final String username;

  /// Identifiant du compte **sur ce serveur**. Deux serveurs numérotent leurs
  /// comptes indépendamment ; ce nombre ne veut donc rien dire ailleurs.
  final int? userId;

  /// Nom donné par l'utilisateur, quand l'adresse ne suffit pas à distinguer
  /// deux serveurs de mémoire.
  final String? label;

  const ServerAccount({
    required this.id,
    required this.url,
    required this.username,
    this.userId,
    this.label,
  });

  /// Ce que l'interface affiche en premier : le nom donné, sinon l'hôte.
  String get displayName {
    final given = label?.trim();
    if (given != null && given.isNotEmpty) return given;
    return prettyHost;
  }

  /// L'adresse débarrassée de son schéma, qui n'apprend rien à personne.
  String get prettyHost {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  ServerAccount copyWith({
    String? url,
    String? username,
    int? userId,
    String? label,
  }) {
    return ServerAccount(
      id: id,
      url: url ?? this.url,
      username: username ?? this.username,
      userId: userId ?? this.userId,
      label: label ?? this.label,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'username': username,
        if (userId != null) 'user_id': userId,
        if (label != null && label!.isNotEmpty) 'label': label,
      };

  factory ServerAccount.fromJson(Map<String, dynamic> json) {
    return ServerAccount(
      id: json['id'] as String,
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      userId: (json['user_id'] as num?)?.toInt(),
      label: json['label'] as String?,
    );
  }

  /// Normalise une adresse saisie à la main : schéma implicite, barre finale,
  /// espaces. Deux écritures de la même adresse doivent donner le même compte,
  /// sinon « ajouter un serveur » en crée un deuxième à chaque frappe près.
  static String normalizeUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// Fabrique l'identifiant de stockage d'un couple (serveur, utilisateur).
  ///
  /// Volontairement réduit à `[a-z0-9_]` : cette chaîne devient une clé de
  /// `flutter_secure_storage`, qui n'accepte pas la même ponctuation sur toutes
  /// les plateformes. L'empreinte numérique en queue rattrape ce que le
  /// nettoyage a écrasé, pour que deux adresses voisines ne se confondent pas.
  static String idFor(String url, String username) {
    final seed = '${normalizeUrl(url)}|${username.trim().toLowerCase()}';
    final slug = seed
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final trimmed = slug.length <= 40 ? slug : slug.substring(slug.length - 40);
    return '${trimmed}_${_hash(seed)}';
  }

  /// FNV-1a 32 bits, en dur plutôt qu'une dépendance : ceci sert à distinguer
  /// des clés locales, pas à protéger quoi que ce soit.
  static String _hash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// Une demande d'accès partie de cet appareil et pas encore tranchée.
///
/// Elle survit au redémarrage de l'app : un administrateur peut mettre des
/// jours à répondre, et personne ne va garder l'écran ouvert en attendant.
class PendingAccessRequest {
  final String url;
  final String username;

  /// Le code privé rendu par le serveur. C'est la seule chose qui permette de
  /// relever la session une fois la demande approuvée — il ne quitte pas cet
  /// appareil.
  final String requestCode;

  final DateTime createdAt;
  final String? label;

  const PendingAccessRequest({
    required this.url,
    required this.username,
    required this.requestCode,
    required this.createdAt,
    this.label,
  });

  String get prettyHost => ServerAccount(
        id: '',
        url: url,
        username: username,
      ).prettyHost;

  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'request_code': requestCode,
        'created_at': createdAt.toIso8601String(),
        if (label != null && label!.isNotEmpty) 'label': label,
      };

  factory PendingAccessRequest.fromJson(Map<String, dynamic> json) {
    return PendingAccessRequest(
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      requestCode: json['request_code'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
      label: json['label'] as String?,
    );
  }
}

/// Le verdict rendu par le serveur au demandeur.
enum AccessRequestStatus { pending, approved, denied, expired }

AccessRequestStatus _statusFrom(String raw) {
  switch (raw) {
    case 'approved':
      return AccessRequestStatus.approved;
    case 'denied':
      return AccessRequestStatus.denied;
    case 'expired':
      return AccessRequestStatus.expired;
    default:
      return AccessRequestStatus.pending;
  }
}

/// Ce que rend `POST /api/auth/access/request` : de quoi revenir chercher le
/// verdict, et rien d'autre.
class AccessRequestTicket {
  final String requestCode;
  final String username;
  final Duration expiresIn;
  final Duration pollInterval;

  const AccessRequestTicket({
    required this.requestCode,
    required this.username,
    required this.expiresIn,
    required this.pollInterval,
  });

  factory AccessRequestTicket.fromJson(Map<String, dynamic> json) {
    return AccessRequestTicket(
      requestCode: json['request_code'] as String? ?? '',
      username: json['username'] as String? ?? '',
      expiresIn: Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 0),
      pollInterval: Duration(seconds: (json['interval'] as num?)?.toInt() ?? 5),
    );
  }
}

/// Ce que rend `POST /api/auth/access/poll`. Le jeton et le profil ne sont
/// remplis que sur une approbation, et une seule fois.
class AccessRequestVerdict {
  final AccessRequestStatus status;
  final String? token;
  final Map<String, dynamic>? user;

  const AccessRequestVerdict({required this.status, this.token, this.user});

  factory AccessRequestVerdict.fromJson(Map<String, dynamic> json) {
    return AccessRequestVerdict(
      status: _statusFrom(json['status'] as String? ?? ''),
      token: json['token'] as String?,
      user: json['user'] as Map<String, dynamic>?,
    );
  }
}

/// Une demande vue depuis l'autre bout : ce que l'administrateur a sous les
/// yeux avant de décider. Ni le code privé du demandeur, ni son mot de passe.
class AccessRequest {
  final int id;
  final String username;
  final String deviceName;
  final String message;
  final String status;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  const AccessRequest({
    required this.id,
    required this.username,
    this.deviceName = '',
    this.message = '',
    this.status = 'pending',
    this.createdAt,
    this.expiresAt,
  });

  factory AccessRequest.fromJson(Map<String, dynamic> json) {
    DateTime? parse(String key) {
      final raw = json[key] as String?;
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw)?.toLocal();
    }

    return AccessRequest(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? '',
      message: json['message'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      createdAt: parse('created_at'),
      expiresAt: parse('expires_at'),
    );
  }
}
