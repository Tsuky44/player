part of '../api_client.dart';

/// Les demandes du compte, lues chez MediaHub (ou OnyxHub) à travers le
/// serveur (ADR-0073, ADR-0089).
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

  Future<bool> supportsMediaHubSso() =>
      _serverSupports(ServerCapabilities.mediaHubSso);

  /// Tire l'adresse qui ouvre MediaHub au nom du compte (ADR-0090). Lève
  /// l'erreur du serveur (503 sans MediaHub, 501 chez OnyxHub).
  Future<MediaHubTicket> openMediaHubTicket() async {
    final response = await _dio.post('/api/integrations/mediahub/sso');
    return MediaHubTicket.fromJson(
        Map<String, dynamic>.from(response.data as Map));
  }

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

  /// Le téléchargement et l'import du titre, lus chez MediaHub. Un serveur ou
  /// un compagnon qui n'a pas la route rend `null`, comme « rien en cours » :
  /// le suivi est un plus, l'écran ne s'en passe pas.
  Future<RequestProgress?> getRequestProgress(
    int tmdbId,
    RequestMediaType mediaType,
  ) async {
    try {
      final response = await _dio.get('/api/requests/progress',
          queryParameters: {'tmdbId': tmdbId, 'type': mediaType.name});
      final progress = RequestProgress.fromJson(
          Map<String, dynamic>.from(response.data as Map));
      return progress.isEmpty ? null : progress;
    } on DioException {
      // Pas de suivi (MediaHub muet, route absente, droit refusé) : l'écran
      // n'affiche simplement pas le cadre.
      return null;
    }
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
