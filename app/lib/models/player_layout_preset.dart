import 'player_layout.dart';

/// A named Player Studio layout owned by the signed-in user and synced to the server.
class PlayerLayoutPreset {
  final String id;
  final String name;
  final PlayerLayoutConfig config;
  final bool useModular;
  final String updatedAt;

  const PlayerLayoutPreset({
    required this.id,
    required this.name,
    required this.config,
    required this.useModular,
    this.updatedAt = '',
  });

  PlayerLayoutPreset copyWith({
    String? id,
    String? name,
    PlayerLayoutConfig? config,
    bool? useModular,
    String? updatedAt,
  }) {
    return PlayerLayoutPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      config: config ?? this.config,
      useModular: useModular ?? this.useModular,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'config': config.toJson(),
        'use_modular': useModular,
        'updated_at': updatedAt,
      };

  factory PlayerLayoutPreset.fromJson(Map<String, dynamic> json) {
    final rawConfig = json['config'];
    final PlayerLayoutConfig config;
    if (rawConfig is Map<String, dynamic>) {
      config = PlayerLayoutConfig.fromJson(rawConfig);
    } else if (rawConfig is String && rawConfig.isNotEmpty) {
      config = PlayerLayoutConfig.decode(rawConfig);
    } else {
      config = PlayerLayoutConfig.standard();
    }

    return PlayerLayoutPreset(
      id: (json['id'] as String?)?.trim() ?? '',
      name: ((json['name'] as String?)?.trim().isNotEmpty ?? false)
          ? (json['name'] as String).trim()
          : 'Mon playeur',
      config: config,
      useModular: json['use_modular'] as bool? ?? false,
      updatedAt: json['updated_at'] as String? ?? '',
    );
  }
}
