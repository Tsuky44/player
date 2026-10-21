part of '../api_client.dart';

/// Ce que la veille des nouvelles demandes demande aux serveurs (ADR-0077).
mixin _RequestFeedEndpoints {
  Future<Dio?> _accountClient(String id);

  /// Les réponses qui veulent dire « ce compte n'a pas de flux » : pas
  /// administrateur (403), serveur d'avant la route (404, 405), OnyxHub non
  /// réglé (503). Un OnyxHub injoignable (502) n'en fait pas partie : il
  /// répondra au passage suivant.
  static const Set<int> _noFeed = {403, 404, 405, 503};

  /// Les demandes faites sur le serveur de [accountId] depuis [after], sur le
  /// client nu du compte, comme [continueWatchingOf] et pour la même raison.
  ///
  /// Null quand ce compte n'a pas de flux. Lève quand le serveur ne répond
  /// pas ou que la session a expiré.
  Future<RequestFeed?> requestFeedOf(String accountId, {int? after}) async {
    final client = await _accountClient(accountId);
    if (client == null) throw StateError('Session expirée');
    try {
      final response = await client.get(
        '/api/requests/feed',
        queryParameters: {if (after != null) 'after': after},
      );
      return RequestFeed.fromJson(
          Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (error) {
      if (_noFeed.contains(error.response?.statusCode)) return null;
      rethrow;
    } finally {
      client.close();
    }
  }
}
