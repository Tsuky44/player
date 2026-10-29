part of '../api_client.dart';

/// Les demandes du compte, lues chez MediaHub (ou OnyxHub) à travers le
/// serveur (ADR-0073, ADR-0087).
mixin _MyRequestEndpoints {
  Dio get _dio;
  String get baseUrl;

  /// Les capacités annoncées, par serveur. Un « non » n'est pas retenu : le
  /// serveur peut être mis à jour pendant que l'app est ouverte.
  final Map<String, Set<String>> _requestCapabilities = {};

  Future<bool> _serverSupports(String capability) async {
    final server = baseUrl;
    if (_requestCapabilities[server]?.contains(capability) ?? false) {
      return true;
    }
    final ping = await _dio.get('/api/ping');
    final info = ServerCapabilities.tryParse(ping.data);
    if (info == null || !info.supports(capability)) return false;
    (_requestCapabilities[server] ??= {}).add(capability);
    return true;
  }

  Future<bool> supportsMyRequests() =>
      _serverSupports(ServerCapabilities.myRequests);

  /// Les plus récentes d'abord.
  Future<List<MyRequest>> getMyRequests() => _requestLots('/api/requests/mine');

  /// Celles de tous les comptes (`manage_settings` chez Onyx, `read
  /// MediaRequest` chez MediaHub).
  Future<List<MyRequest>> getAllRequests() => _requestLots('/api/requests/all');

  Future<List<MyRequest>> _requestLots(String path) async {
    final response = await _dio.get(path);
    final raw =
        (response.data as Map)['requests'] as List<dynamic>? ?? const [];
    return raw
        .map((e) => MyRequest.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Les droits du compte chez le compagnon. Un serveur d'avant MediaHub v1
  /// ne connaît que demander et lire ses demandes : [RequestAccess.basic].
  Future<RequestAccess> getRequestAccess() async {
    if (!await _serverSupports(ServerCapabilities.mediaHubRequests)) {
      return RequestAccess.basic;
    }
    final response = await _dio.get('/api/requests/access');
    return RequestAccess.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

  /// Approuve, refuse ou supprime les lignes d'un lot. Lève l'erreur de
  /// MediaHub (403, 409…), que l'écran affiche.
  Future<void> moderateRequests(
    List<int> requestIds,
    RequestModeration action, {
    String? reason,
  }) async {
    await _dio.post('/api/requests/moderation', data: {
      'requestIds': requestIds,
      'action': action.name,
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    });
  }
}
