part of '../api_client.dart';

/// Ce que la veille des nouveaux épisodes demande aux serveurs (ADR-0059).
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _NewEpisodeEndpoints {
  Future<Dio?> _accountClient(String id);

  /// « À reprendre » du compte [accountId], qu'il soit actif ou non.
  ///
  /// Sur le client nu d'un compte, avec son jeton à lui, et sans les en-têtes
  /// d'identité : la tâche de fond n'a pas accès au nom de l'appareil, et en
  /// envoyer un autre renommerait la session dans la liste des appareils
  /// connectés. Lève quand le compte n'a plus de jeton ou que le serveur ne
  /// répond pas.
  Future<List<HomeMediaItem>> continueWatchingOf(String accountId) async {
    final client = await _accountClient(accountId);
    if (client == null) throw StateError('Session expirée');
    try {
      final response = await client.get(
        '/api/home',
        options: Options(
          headers: {'Accept-Language': AppLanguage.current.code},
        ),
      );
      return HomeResponse.fromJson(response.data as Map<String, dynamic>)
          .continueWatching;
    } finally {
      client.close();
    }
  }
}
