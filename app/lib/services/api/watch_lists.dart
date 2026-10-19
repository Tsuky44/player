part of '../api_client.dart';

/// Les listes du compte : « À regarder plus tard » et les siennes, partagées
/// ou non (ADR-0070).
mixin _WatchListEndpoints {
  Dio get _dio;
  String get baseUrl;

  /// Les serveurs qui ont annoncé `watch_lists` sur `/api/ping`. Un « non »
  /// n'est pas retenu : le serveur peut être mis à jour pendant que l'app est
  /// ouverte.
  final Set<String> _serversWithWatchLists = {};

  /// Le serveur actif sait-il tenir des listes ?
  Future<bool> supportsWatchLists() async {
    final server = baseUrl;
    if (_serversWithWatchLists.contains(server)) return true;
    final ping = await _dio.get('/api/ping');
    final info = ServerCapabilities.tryParse(ping.data);
    if (info == null || !info.supports(ServerCapabilities.watchLists)) {
      return false;
    }
    _serversWithWatchLists.add(server);
    return true;
  }

  /// Les listes du compte et celles que les autres partagent. Avec
  /// [containing], chacune des listes du compte dit si elle a déjà ce titre.
  Future<WatchListsOverview> getWatchLists({ListableTitle? containing}) async {
    final response =
        await _dio.get('/api/lists', queryParameters: containing?.probe);
    return WatchListsOverview.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  Future<WatchListDetail> getWatchList(int id) async {
    final response = await _dio.get('/api/lists/$id');
    return WatchListDetail.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  Future<WatchList> createWatchList({
    required String name,
    String description = '',
    bool isShared = false,
  }) async {
    final response = await _dio.post('/api/lists', data: {
      'name': name,
      'description': description,
      'is_shared': isShared,
    });
    return WatchList.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  /// Renomme une liste, change sa description ou son partage. « À regarder
  /// plus tard » ne garde que le partage.
  Future<WatchList> updateWatchList(
    int id, {
    required String name,
    required String description,
    required bool isShared,
  }) async {
    final response = await _dio.put('/api/lists/$id', data: {
      'name': name,
      'description': description,
      'is_shared': isShared,
    });
    return WatchList.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  Future<void> deleteWatchList(int id) async {
    await _dio.delete('/api/lists/$id');
  }

  /// Range un titre dans une liste. Un titre déjà présent revient tel quel.
  Future<WatchListItem> addToWatchList(int listId, ListableTitle title) async {
    final response =
        await _dio.post('/api/lists/$listId/items', data: title.toJson());
    return WatchListItem.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  Future<void> removeFromWatchList(int listId, int itemId) async {
    await _dio.delete('/api/lists/$listId/items/$itemId');
  }
}
