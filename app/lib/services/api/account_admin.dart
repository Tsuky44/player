part of '../api_client.dart';

/// Comptes, invitations et demandes d'accès.
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _AccountAdminEndpoints {
  Dio get _dio;
  String get baseUrl;
  Future<void> clearAuth();
  Future<ServerAccount> rememberSession({
    required String serverUrl,
    required String username,
    required String token,
    int? userId,
    bool activate,
  });

  // ==================== USERS & INVITATIONS ====================

  Future<List<User>> getUsers() async {
    final response = await _dio.get("/api/users");
    return (response.data as List<dynamic>)
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Rewrites a user's rights. [inviteGrants] is the template their own
  /// invitation links will apply; it is the admin who picks it, never them.
  Future<User> updateUserPermissions(
    int userId,
    Permissions permissions, {
    Permissions? inviteGrants,
  }) async {
    final response = await _dio.put("/api/users/$userId/permissions", data: {
      "permissions": permissions.toJson(),
      if (inviteGrants != null) "invite_grants": inviteGrants.toJson(),
    });
    return User.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> resetUserPassword(int userId, String newPassword) async {
    await _dio.post("/api/users/$userId/password",
        data: {"new_password": newPassword});
  }

  Future<void> deleteUser(int userId) async {
    await _dio.delete("/api/users/$userId");
  }

  Future<void> transferOwnership(int userId) async {
    await _dio.post("/api/users/$userId/transfer-ownership");
  }

  Future<List<Invitation>> getInvitations() async {
    final response = await _dio.get("/api/invitations");
    return (response.data as List<dynamic>)
        .map((e) => Invitation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Invitation> createInvitation({Permissions? grants}) async {
    final response = await _dio.post(
      "/api/invitations",
      data: grants == null ? null : {"grants": grants.toJson()},
    );
    return Invitation.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> revokeInvitation(String token) async {
    await _dio.delete("/api/invitations/$token");
  }

  /// The shareable link for an invitation. The server cannot build this itself
  /// — behind a proxy or a tunnel it has no idea what its public address is —
  /// so it is composed from the address this client is actually connected to.
  /// That address may be LAN-only, which is why the raw code is shown next to
  /// it: on the native apps it is the only usable path anyway.
  String invitationLink(Invitation invitation) {
    return "$baseUrl/?invite=${invitation.token}";
  }

  // ==================== DEMANDES D'ACCÈS ====================
  //
  // Deux moitiés qui ne parlent pas au même serveur.
  //
  // Côté demandeur, les appels visent un serveur **autre** que celui où la
  // session est ouverte, et ils partent donc sur un Dio nu : l'intercepteur
  // habituel poserait l'en-tête `Authorization` du compte actif, c'est-à-dire
  // qu'il confierait la session ouverte chez l'un à l'autre. Ces routes sont
  // ouvertes de toute façon — le demandeur n'a précisément pas de compte là-bas.
  //
  // Côté décideur, ce sont des appels ordinaires sur le serveur actif.

  /// Un client sans intercepteur, pour parler à un serveur tiers sans rien lui
  /// présenter de ce qui appartient au serveur actif.
  Dio _bareClient() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
      ));

  /// Sonne à la porte d'un serveur : propose un identifiant, attend un verdict.
  /// Rien n'est créé là-bas tant que personne n'a approuvé.
  Future<AccessRequestTicket> requestAccess({
    required String serverUrl,
    required String username,
    required String password,
    String? deviceName,
    String? message,
  }) async {
    final url = ServerAccount.normalizeUrl(serverUrl);
    final response = await _bareClient().post(
      "$url/api/auth/access/request",
      data: {
        "username": username,
        "password": password,
        if (deviceName != null && deviceName.isNotEmpty)
          "device_name": deviceName,
        if (message != null && message.isNotEmpty) "message": message,
      },
    );
    return AccessRequestTicket.fromJson(response.data as Map<String, dynamic>);
  }

  /// Demande le verdict. Sur une approbation, la session est remise une seule
  /// fois : ce qui en est fait ensuite regarde [rememberSession].
  Future<AccessRequestVerdict> pollAccessRequest({
    required String serverUrl,
    required String requestCode,
  }) async {
    final url = ServerAccount.normalizeUrl(serverUrl);
    final response = await _bareClient().post(
      "$url/api/auth/access/poll",
      data: {"request_code": requestCode},
    );
    return AccessRequestVerdict.fromJson(response.data as Map<String, dynamic>);
  }

  /// Ouvre une session sur un serveur tiers sans quitter celui qui est actif.
  ///
  /// C'est le cas de l'utilisateur qui a **déjà** un compte ailleurs : rien à
  /// demander à personne, il suffit de le rentrer au carnet. Sur le Dio nu pour
  /// la même raison que les demandes d'accès — le jeton du serveur actif n'a
  /// rien à faire dans cet appel.
  Future<User> signInAt({
    required String serverUrl,
    required String username,
    required String password,
    bool activate = false,
  }) async {
    final url = ServerAccount.normalizeUrl(serverUrl);
    final response = await _bareClient().post(
      "$url/api/auth/login",
      data: {"username": username, "password": password},
    );
    final token = response.data["token"] as String;
    final user = User.fromJson(response.data["user"] as Map<String, dynamic>);
    await rememberSession(
      serverUrl: url,
      username: user.username,
      token: token,
      userId: user.id,
      activate: activate,
    );
    return user;
  }

  /// Les demandes en attente sur le serveur actif.
  Future<List<AccessRequest>> getAccessRequests() async {
    final response = await _dio.get("/api/access-requests");
    return (response.data as List<dynamic>)
        .map((e) => AccessRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Accepte une demande. [permissions] n'est honoré que pour un titulaire de
  /// `manage_users` ; un simple inviteur accorde son gabarit, quoi qu'il envoie.
  Future<User> approveAccessRequest(int id, {Permissions? permissions}) async {
    final response = await _dio.post(
      "/api/access-requests/$id/approve",
      data: permissions == null ? null : {"permissions": permissions.toJson()},
    );
    return User.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> denyAccessRequest(int id) async {
    await _dio.post("/api/access-requests/$id/deny");
  }

  Future<User> login(String username, String password) async {
    final response = await _dio.post("/api/auth/login", data: {
      "username": username,
      "password": password,
    });

    final token = response.data["token"] as String;
    final userJson = response.data["user"] as Map<String, dynamic>;
    final user = User.fromJson(userJson);

    await rememberSession(
      serverUrl: baseUrl,
      username: user.username,
      token: token,
      userId: user.id,
    );
    return user;
  }

  Future<User> getMe() async {
    final response = await _dio.get("/api/auth/me");
    return User.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    try {
      await _dio.post("/api/auth/logout");
    } catch (_) {}
    await clearAuth();
  }
}
