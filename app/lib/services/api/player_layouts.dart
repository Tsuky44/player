part of '../api_client.dart';

/// Les dispositions du Player Studio.
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _PlayerLayoutEndpoints {
  Dio get _dio;

  // ==================== PLAYER STUDIO LAYOUTS ====================

  Future<List<PlayerLayoutPreset>> listPlayerLayouts() async {
    final response = await _dio.get('/api/me/player-layouts');
    final data = response.data;
    final list = data is Map ? data['layouts'] as List? ?? const [] : const [];
    return list
        .whereType<Map>()
        .map((e) => PlayerLayoutPreset.fromJson(Map<String, dynamic>.from(e)))
        .where((p) => p.id.isNotEmpty)
        .toList();
  }

  Future<PlayerLayoutPreset> createPlayerLayout({
    required String name,
    required PlayerLayoutConfig config,
    required bool useModular,
  }) async {
    final response = await _dio.post('/api/me/player-layouts', data: {
      'name': name,
      'config': config.toJson(),
      'use_modular': useModular,
    });
    return PlayerLayoutPreset.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  Future<PlayerLayoutPreset> updatePlayerLayout({
    required String id,
    String? name,
    PlayerLayoutConfig? config,
    bool? useModular,
  }) async {
    final response = await _dio.put('/api/me/player-layouts/$id', data: {
      if (name != null) 'name': name,
      if (config != null) 'config': config.toJson(),
      if (useModular != null) 'use_modular': useModular,
    });
    return PlayerLayoutPreset.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  Future<void> deletePlayerLayout(String id) async {
    await _dio.delete('/api/me/player-layouts/$id');
  }
}
