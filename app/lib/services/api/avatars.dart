part of '../api_client.dart';

/// L'image de profil (ADR-0078).
///
/// Chaque appel vise un compte du carnet et non le compte actif : depuis
/// « Qui regarde ? », on change l'image de quelqu'un dont la session n'est pas
/// ouverte. Il part donc sur un client nu, avec le jeton de **ce** compte,
/// vers **son** serveur — jamais celui d'un autre (ADR-0013).
mixin _AvatarEndpoints {
  ServerRegistry get servers;
  Dio _bareClient();

  Future<Options> _optionsFor(ServerAccount account) async {
    final token = await servers.tokenFor(account.id);
    if (token == null) {
      throw StateError(tr('Ce compte doit se reconnecter sur cet appareil.'));
    }
    return Options(headers: {'Authorization': 'Bearer $token'});
  }

  /// Choisit un avatar de la galerie, ou revient à l'initiale avec `null`.
  Future<User> setAvatarPreset(ServerAccount account, String? key) async {
    final response = await _bareClient().put(
      '${account.url}/api/me/avatar',
      data: {'preset': key ?? ''},
      options: await _optionsFor(account),
    );
    return _rememberAvatar(account, response.data);
  }

  /// Envoie la photo, déjà recadrée et réduite par l'app.
  Future<User> uploadAvatarPhoto(ServerAccount account, Uint8List png) async {
    final options = await _optionsFor(account);
    final response = await _bareClient().post(
      '${account.url}/api/me/avatar/photo',
      data: Stream.fromIterable([png]),
      options: options.copyWith(
        contentType: 'image/png',
        headers: {
          ...?options.headers,
          Headers.contentLengthHeader: png.length,
        },
      ),
    );
    return _rememberAvatar(account, response.data);
  }

  /// La photo de [account], lue avec son propre jeton. `null` quand il n'en a
  /// plus — remplacée depuis un autre appareil.
  Future<Uint8List?> fetchAvatarPhoto(ServerAccount account) async {
    final userId = account.userId;
    if (userId == null) return null;
    try {
      final response = await _bareClient().get<List<int>>(
        '${account.url}/api/users/$userId/avatar',
        options: (await _optionsFor(account))
            .copyWith(responseType: ResponseType.bytes),
      );
      final data = response.data;
      return data == null ? null : Uint8List.fromList(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<User> _rememberAvatar(ServerAccount account, dynamic data) async {
    final user = User.fromJson(Map<String, dynamic>.from(data as Map));
    await servers.setAvatar(account.id, user.avatar);
    return user;
  }
}
