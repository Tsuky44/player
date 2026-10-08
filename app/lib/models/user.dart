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

  /// Créer des liens publics vers un film ou un épisode (ADR-0037).
  final bool shareMedia;

  const Permissions({
    this.manageSettings = false,
    this.manageLibrary = false,
    this.manageUsers = false,
    this.deleteMedia = false,
    this.inviteUsers = false,
    this.requestMedia = false,
    this.shareMedia = false,
  });

  /// What the "Admin" shortcut ticks.
  static const all = Permissions(
    manageSettings: true,
    manageLibrary: true,
    manageUsers: true,
    deleteMedia: true,
    inviteUsers: true,
    requestMedia: true,
    shareMedia: true,
  );

  bool get isAdmin =>
      manageSettings &&
      manageLibrary &&
      manageUsers &&
      deleteMedia &&
      inviteUsers &&
      requestMedia &&
      shareMedia;

  /// True when nothing at all is granted — used to label an empty template.
  bool get isEmpty =>
      !manageSettings &&
      !manageLibrary &&
      !manageUsers &&
      !deleteMedia &&
      !inviteUsers &&
      !requestMedia &&
      !shareMedia;

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
      shareMedia: flag('share_media'),
    );
  }

  Map<String, dynamic> toJson() => {
        'manage_settings': manageSettings,
        'manage_library': manageLibrary,
        'manage_users': manageUsers,
        'delete_media': deleteMedia,
        'invite_users': inviteUsers,
        'request_media': requestMedia,
        'share_media': shareMedia,
      };

  Permissions copyWith({
    bool? manageSettings,
    bool? manageLibrary,
    bool? manageUsers,
    bool? deleteMedia,
    bool? inviteUsers,
    bool? requestMedia,
    bool? shareMedia,
  }) {
    return Permissions(
      manageSettings: manageSettings ?? this.manageSettings,
      manageLibrary: manageLibrary ?? this.manageLibrary,
      manageUsers: manageUsers ?? this.manageUsers,
      deleteMedia: deleteMedia ?? this.deleteMedia,
      inviteUsers: inviteUsers ?? this.inviteUsers,
      requestMedia: requestMedia ?? this.requestMedia,
      shareMedia: shareMedia ?? this.shareMedia,
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

  /// Le compte a configuré la validation en deux étapes (ADR-0041).
  final bool otpEnabled;

  User({
    required this.id,
    required this.username,
    this.isOwner = false,
    this.permissions = const Permissions(),
    this.inviteGrants = const Permissions(),
    this.otpEnabled = false,
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
      otpEnabled: json['otp_enabled'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'is_owner': isOwner,
      'permissions': permissions.toJson(),
      'invite_grants': inviteGrants.toJson(),
      'otp_enabled': otpEnabled,
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
