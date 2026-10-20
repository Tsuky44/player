part of '../api_client.dart';

/// Les demandes du compte, lues chez OnyxHub à travers le serveur (ADR-0073).
mixin _MyRequestEndpoints {
  Dio get _dio;
  String get baseUrl;

  /// Les serveurs qui ont annoncé `my_requests`. Un « non » n'est pas retenu :
  /// le serveur peut être mis à jour pendant que l'app est ouverte.
  final Set<String> _serversWithMyRequests = {};

  Future<bool> supportsMyRequests() async {
    final server = baseUrl;
    if (_serversWithMyRequests.contains(server)) return true;
    final ping = await _dio.get('/api/ping');
    final info = ServerCapabilities.tryParse(ping.data);
    if (info == null || !info.supports(ServerCapabilities.myRequests)) {
      return false;
    }
    _serversWithMyRequests.add(server);
    return true;
  }

  /// Les plus récentes d'abord.
  Future<List<MyRequest>> getMyRequests() async {
    final response = await _dio.get('/api/requests/mine');
    final raw =
        (response.data as Map)['requests'] as List<dynamic>? ?? const [];
    return raw
        .map((e) => MyRequest.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
