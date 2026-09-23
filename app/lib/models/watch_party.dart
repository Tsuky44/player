import 'models.dart';

/// Un participant d'une séance « Regarder ensemble », tel que le serveur le
/// montre à un autre : son nom et son appareil, jamais son identifiant.
class WatchPartyMember {
  const WatchPartyMember({
    required this.username,
    this.device,
    this.isHost = false,
    this.isYou = false,
  });

  final String username;
  final String? device;
  final bool isHost;
  final bool isYou;

  factory WatchPartyMember.fromJson(Map<String, dynamic> json) {
    final device = json['device'] as String?;
    return WatchPartyMember(
      username: json['username'] as String? ?? '',
      device: device == null || device.isEmpty ? null : device,
      isHost: json['is_host'] as bool? ?? false,
      isYou: json['is_you'] as bool? ?? false,
    );
  }
}

/// Le dernier geste appliqué à la séance, pour l'annoncer aux autres.
class WatchPartyAction {
  const WatchPartyAction({
    required this.kind,
    required this.username,
    required this.byYou,
    required this.version,
  });

  /// `play`, `pause`, `seek`, `media`, `join` ou `leave`.
  final String kind;
  final String username;
  final bool byYou;
  final int version;

  factory WatchPartyAction.fromJson(Map<String, dynamic> json) =>
      WatchPartyAction(
        kind: json['kind'] as String? ?? '',
        username: json['username'] as String? ?? '',
        byYou: json['by_you'] as bool? ?? false,
        version: (json['version'] as num?)?.toInt() ?? 0,
      );
}

/// L'état de référence d'une séance à l'instant où le serveur a répondu.
///
/// [position] est déjà extrapolée par le serveur au moment de la réponse :
/// l'appareil n'a qu'à y ajouter le temps écoulé depuis [receivedAt], sans
/// jamais comparer son horloge à celle du serveur.
class WatchPartySnapshot {
  WatchPartySnapshot({
    required this.code,
    required this.memberId,
    required this.version,
    required this.mediaId,
    required this.media,
    required this.playing,
    required this.position,
    required this.members,
    required this.lastAction,
    required this.receivedAt,
  });

  final String code;
  final String memberId;
  final int version;
  final int mediaId;

  /// Le média tel que ce compte le voit — de quoi ouvrir le lecteur dessus.
  final HomeMediaItem? media;
  final bool playing;
  final Duration position;
  final List<WatchPartyMember> members;
  final WatchPartyAction? lastAction;

  /// Horloge monotone locale, au moment de la réception.
  final Duration receivedAt;

  /// Où la séance en est « maintenant », d'après cet état.
  Duration expectedPosition(Duration now) {
    if (!playing) return position;
    final elapsed = now - receivedAt;
    return position + (elapsed.isNegative ? Duration.zero : elapsed);
  }

  factory WatchPartySnapshot.fromJson(
    Map<String, dynamic> json, {
    required Duration receivedAt,
  }) {
    final media = json['media'];
    final seconds = (json['position_seconds'] as num?)?.toDouble() ?? 0;
    final action = json['last_action'];
    return WatchPartySnapshot(
      code: json['code'] as String? ?? '',
      memberId: json['member_id'] as String? ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      mediaId: (json['media_id'] as num?)?.toInt() ?? 0,
      media: media is Map<String, dynamic>
          ? HomeMediaItem.fromJson(media)
          : null,
      playing: json['playing'] as bool? ?? false,
      position: Duration(milliseconds: (seconds * 1000).round()),
      members: [
        for (final m in (json['members'] as List? ?? const []))
          if (m is Map<String, dynamic>) WatchPartyMember.fromJson(m),
      ],
      lastAction: action is Map<String, dynamic>
          ? WatchPartyAction.fromJson(action)
          : null,
      receivedAt: receivedAt,
    );
  }
}
