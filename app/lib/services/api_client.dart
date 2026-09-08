import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_download.dart';
import '../models/device_pairing.dart';
import '../models/server_account.dart';
import 'playback_capabilities.dart';
import 'server_registry.dart';
import 'progress_sync.dart';
import 'media_failover.dart';
import '../models/media_request.dart';
import '../utils/app_platform.dart';
import '../models/request_catalog_filters.dart';
import '../models/models.dart';
import '../models/player_layout.dart';
import '../models/player_layout_preset.dart';

/// Holds the result of starting an HLS transcoding session.
///
/// [masterUrl] is opened directly by media_kit/mpv, which fetches the child
/// playlists and segments itself (no local temp file, no playlist rewriting).
class HlsSession {
  final String sessionId;
  final String masterUrl;
  final double totalDuration; // full media duration in seconds
  final int startOffset; // seconds into the original media

  /// Source audio tracks published as HLS renditions, in the order the player
  /// enumerates them: position k in the player's audio track list is source
  /// track `audioMap[k]`. This is what lets a language change be an mpv track
  /// switch instead of a whole new transcoding session.
  final List<int> audioMap;

  /// Bitmap subtitle stream the server actually rendered into the video, or -1.
  /// It can differ from what was requested when the track turned out not to be
  /// burnable, so the client should trust this rather than its own request.
  final int burnedSubtitle;

  /// `copy` when the server is repackaging the picture untouched, `encode` when
  /// it is re-encoding it. Empty from a server that predates the field.
  ///
  /// Worth surfacing rather than guessing: "Direct Stream" and "why is the
  /// server's CPU at 400%" are the same question, and only the server knows.
  final String videoMode;

  /// Why a copy was refused, in the server's own words. Empty on the copy path.
  final String videoReason;

  HlsSession({
    required this.sessionId,
    required this.masterUrl,
    required this.totalDuration,
    required this.startOffset,
    this.audioMap = const [],
    this.burnedSubtitle = -1,
    this.videoMode = '',
    this.videoReason = '',
  });

  /// True when the picture is reaching the viewer untouched.
  bool get isDirectStream => videoMode == 'copy';

  factory HlsSession.fromJson(Map<String, dynamic> json) {
    return HlsSession(
      sessionId: json['session_id'] as String? ?? '',
      masterUrl: json['master_url'] as String? ?? '',
      totalDuration: (json['duration'] as num? ?? 0).toDouble(),
      startOffset: json['start_offset'] as int? ?? 0,
      audioMap: (json['audio_map'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      burnedSubtitle: (json['burned_subtitle'] as num?)?.toInt() ?? -1,
      videoMode: json['video_mode'] as String? ?? '',
      videoReason: json['video_reason'] as String? ?? '',
    );
  }
}

class ApiClient {
  static String get _defaultBaseUrl {
    // On web the Go server serves this very bundle, so the page origin is
    // already the API root. Hardcoding a host here would turn every call into a
    // cross-origin request against whatever machine the user is browsing from.
    if (AppPlatform.isWeb) return Uri.base.origin;
    return AppPlatform.isAndroid
        ? 'http://10.0.2.2:8080'
        : 'http://127.0.0.1:8080';
  }

  /// Prévenu quand un appel n'a pas pu joindre le serveur (DNS, refus de
  /// connexion, délai dépassé) — par opposition à un appel arrivé à
  /// destination et refusé, qui prouve au contraire que le serveur est là.
  ///
  /// C'est [ServerReachability] qui s'y branche : un échec réel vaut mieux
  /// qu'un sondage pour savoir qu'on vient de basculer hors ligne.
  static void Function()? onConnectionError;

  /// Prévenu quand une réponse arrive — la preuve la moins chère qu'il y a un
  /// serveur au bout.
  static void Function()? onConnectionSuccess;

  final Dio _dio;

  /// Les serveurs auxquels cet appareil a un compte. Le client ne détient plus
  /// « une » adresse et « un » jeton : il applique ceux du compte actif, et
  /// changer de serveur revient à en désigner un autre. Voir ADR-0013.
  final ServerRegistry servers;
  late final MediaFailover mediaFailover = MediaFailover(servers);
  String? _pinnedAccountId;
  String? get accountId => _pinnedAccountId ?? servers.active?.id;
  late final ProgressSync _progressSync;
  void Function()? onProgressSynchronized;

  String? _baseUrl;
  String? _token;
  String? _savedUsername;
  bool _configLoaded = false;

  /// Whether the address in [baseUrl] was ever chosen, as opposed to falling
  /// back to the per-platform default.
  ///
  /// The Android default is the emulator's loopback alias: right on a developer
  /// machine, unreachable on every real device. A television on a fresh install
  /// has to know the difference — it is the cue to go looking for the server
  /// instead of spending ten seconds timing out against 10.0.2.2.
  bool _serverChosen = false;

  /// Loads persisted server URL and auth token. Call once at app startup.
  Future<void> initialize() async {
    await _loadConfig();
  }

  ApiClient(
      {ServerRegistry? registry, Dio? httpClient, ProgressSync? progressSync})
      : servers = registry ?? ServerRegistry(),
        _dio = httpClient ?? Dio() {
    _progressSync = progressSync ?? ProgressSync(servers);
    _dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (!_configLoaded) {
        await _loadConfig();
      }
      options.baseUrl = _baseUrl ?? _defaultBaseUrl;

      // Le jeton envoyé est celui du compte actif, et rien d'autre : pointer
      // le client sur une autre adresse le met à nul plutôt que de présenter
      // à un serveur la session ouverte sur un autre.
      if (_token != null) {
        options.headers["Authorization"] = "Bearer $_token";
      }

      options.connectTimeout = const Duration(seconds: 10);
      options.receiveTimeout = const Duration(seconds: 30);

      return handler.next(options);
    }, onResponse: (response, handler) {
      if (_pinnedAccountId == null || _pinnedAccountId == servers.active?.id)
        onConnectionSuccess?.call();
      return handler.next(response);
    }, onError: (DioException e, handler) {
      // Global error logging
      print(
          "API Error [${e.requestOptions.method}] ${e.requestOptions.path}: ${e.message}");
      switch (e.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
          if (_pinnedAccountId == null ||
              _pinnedAccountId == servers.active?.id) onConnectionError?.call();
        default:
          // Une réponse, même 500, prouve qu'il y a quelqu'un en face.
          if (e.response != null) if (_pinnedAccountId == null ||
              _pinnedAccountId == servers.active?.id)
            onConnectionSuccess?.call();
      }
      return handler.next(e);
    }));
  }

  /// A running player keeps its source even if the app selects another server.
  Future<ApiClient> pinToAccount(String id) async {
    final account = servers.accountById(id);
    if (account == null) throw StateError('Compte indisponible');
    final token = await servers.tokenFor(id);
    final pinned = ApiClient(registry: servers);
    pinned._pinnedAccountId = id;
    pinned._baseUrl = account.url;
    pinned._token = token;
    pinned._configLoaded = true;
    pinned._serverChosen = true;
    return pinned;
  }

  Future<void> synchronizeLinkedProgress() async {
    for (final account in servers.accounts) {
      unawaited(mediaFailover.refreshIdentities(account.id));
    }
    await _progressSync.synchronize(force: true);
  }

  // Get current active base URL
  String get baseUrl => _baseUrl ?? _defaultBaseUrl;

  /// True once a server address has been picked — remembered from a previous
  /// run, entered by hand, or found on the network — rather than defaulted.
  bool get hasChosenServer => _serverChosen;

  String? get savedUsername => _savedUsername;

  bool get hasSavedToken => _token != null && _token!.isNotEmpty;

  Future<void> saveLastUsername(String username) async {
    final value = username.trim();
    if (value.isEmpty) return;
    _savedUsername = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_username', value);
  }

  // Stream URL generator (Direct Play)
  String getStreamUrl(int mediaId) {
    return "$baseUrl/stream?media_id=$mediaId";
  }

  // HLS session destroy URL (to notify server on stop)
  String getHlsDestroyUrl(int mediaId, String sessionId) {
    return "$baseUrl/api/v1/stream/$mediaId/$sessionId";
  }

  /// URL of an external WebVTT subtitle for a given language. [start] shifts the
  /// timeline to match an HLS stream that begins at an offset; Direct Play uses 0.
  String getSubtitleUrl(int mediaId, String lang, {int start = 0}) {
    // URL ends in ".vtt" so libmpv/media_kit detects the WebVTT parser from the
    // extension; without it the external track silently fails to load.
    return "$baseUrl/api/v1/media/$mediaId/subtitles/$lang.vtt?start=$start";
  }

  /// Download the raw WebVTT text for a subtitle. Fetching it ourselves and
  /// injecting via SubtitleTrack.data() is far more reliable than asking mpv to
  /// fetch a URL while it is already busy pulling an HLS stream.
  Future<String> fetchSubtitleContent(int mediaId, String lang,
      {int start = 0}) async {
    final response = await _dio.get<String>(
      "/api/v1/media/$mediaId/subtitles/$lang.vtt",
      queryParameters: {"start": start},
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? "";
  }

  /// Start an HLS transcoding session and return its descriptor. The server
  /// blocks until the first segment is ready, so the returned [HlsSession.masterUrl]
  /// can be opened immediately by the player.
  Future<HlsSession> startHlsSession(
    int mediaId,
    String quality, {
    int startSeconds = 0,
    int audioIndex = 0,
    int burnSubtitleIndex = -1,
  }) async {
    final stopwatch = Stopwatch()..start();
    final response = await _dio.post(
      "/api/v1/stream/$mediaId/start",
      queryParameters: {
        "quality": quality,
        "start": startSeconds,
        "audio": audioIndex,
        // Bitmap subtitles have no out-of-band form, so the transcoder paints
        // the chosen one into the video. -1 means none.
        "burnsub": burnSubtitleIndex,
        // What this device can decode and play back. Without it the server
        // assumes the weakest client it has ever had to serve — H.264 8-bit and
        // stereo AAC — and re-encodes a file this one could have taken as it is.
        ...PlaybackCapabilitiesResolver.current.toQueryParameters(),
      },
    );
    stopwatch.stop();
    final session = HlsSession.fromJson(response.data as Map<String, dynamic>);
    // Logs both what was ASKED (startSeconds) and what the server CONFIRMS
    // (session.startOffset) side by side — the fastest way to tell whether a
    // seek landing at the wrong position is a client bug (mismatch here) or
    // something downstream (the two agree, but playback still drifts).
    print("ApiClient: startHlsSession took ${stopwatch.elapsedMilliseconds}ms "
        "for media $mediaId quality $quality audio $audioIndex "
        "requestedStart=${startSeconds}s confirmedStart=${session.startOffset}s "
        "video=${session.videoMode}"
        "${session.videoReason.isEmpty ? '' : ' (${session.videoReason})'} "
        "session=${session.sessionId}");
    return session;
  }

  // Notify server to destroy an HLS transcoding session (kills FFmpeg + temp files)
  Future<void> destroyHlsSession(int mediaId, String sessionId) async {
    if (sessionId.isEmpty) return;
    try {
      await _dio.delete(getHlsDestroyUrl(mediaId, sessionId));
    } catch (_) {
      // Best-effort: the server reaper cleans up idle sessions anyway.
    }
  }

  /// Points the client at an address, without claiming an account there.
  ///
  /// C'est le chemin de l'écran de connexion : on désigne un serveur avant de
  /// savoir si on y a un compte. Si l'adresse correspond à un compte déjà
  /// enregistré, elle le réactive — sinon la session en cours est **laissée
  /// intacte en mémoire de registre**, mais le jeton cesse d'être envoyé : le
  /// présenter à un autre serveur reviendrait à lui confier une session qui ne
  /// le concerne pas.
  Future<void> setConnection(String serverUrl, {String? token}) async {
    final formattedUrl = ServerAccount.normalizeUrl(serverUrl);

    await servers.load();
    final match = servers.accountForUrl(formattedUrl);
    if (token == null && match != null) {
      await servers.activate(match.id);
      await _applyActiveAccount();
      await _rememberLastAddress(formattedUrl);
      return;
    }

    _baseUrl = formattedUrl;
    _serverChosen = true;
    await _rememberLastAddress(formattedUrl);

    if (token != null) {
      _token = token;
    } else {
      _token = null;
    }
  }

  /// L'adresse retenue pour préremplir l'écran de connexion au prochain
  /// lancement — un confort d'affichage, pas une session.
  Future<void> _rememberLastAddress(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_url", url);
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await servers.load();
    final savedUrl = prefs.getString('server_url');
    // On web the page origin *is* the server, so the default is never a guess.
    _serverChosen =
        savedUrl != null || AppPlatform.isWeb || servers.active != null;
    _savedUsername = prefs.getString('last_username');
    _configLoaded = true;

    final active = servers.active;
    if (active != null) {
      _baseUrl = active.url;
      _token = await servers.tokenFor(active.id);
      return;
    }
    _baseUrl = savedUrl ?? _defaultBaseUrl;
    _token = null;
  }

  /// Recopie le compte actif du registre dans l'état du client.
  Future<void> _applyActiveAccount() async {
    final active = servers.active;
    if (active == null) {
      _token = null;
      return;
    }
    _baseUrl = active.url;
    _serverChosen = true;
    _token = await servers.tokenFor(active.id);
  }

  /// Enregistre la session qui vient d'être ouverte et la rend active.
  ///
  /// Tout ce qui produit une session passe par ici — mot de passe, appairage
  /// TV, demande d'accès approuvée — pour qu'il n'y ait qu'un seul endroit où
  /// un serveur entre dans le carnet.
  Future<ServerAccount> rememberSession({
    required String serverUrl,
    required String username,
    required String token,
    int? userId,
    bool activate = true,
  }) async {
    await servers.load();
    final account = await servers.remember(
      url: serverUrl,
      username: username,
      token: token,
      userId: userId,
      activate: activate,
    );
    if (servers.active?.id != account.id) return account;

    _baseUrl = account.url;
    _serverChosen = true;
    _token = token;
    await _rememberLastAddress(account.url);
    await saveLastUsername(username);
    return account;
  }

  /// Bascule sur un compte déjà enregistré. Rend faux quand il a disparu.
  Future<bool> activateAccount(String id, {bool synchronize = true}) async {
    await servers.load();
    if (!await servers.activate(id)) return false;
    await _applyActiveAccount();
    final active = servers.active;
    if (active != null) {
      await _rememberLastAddress(active.url);
      await saveLastUsername(active.username);
    }
    if (synchronize) {
      unawaited(_progressSync.synchronize(force: true).then((_) {
        if (accountId == id) onProgressSynchronized?.call();
      }));
    }
    return true;
  }

  /// Change l'adresse du compte actif sans toucher à sa session.
  Future<void> updateActiveServerUrl(String url) async {
    await servers.load();
    final active = servers.active;
    if (active == null) {
      await setConnection(url);
      return;
    }
    await servers.updateUrl(active.id, url);
    await _applyActiveAccount();
    await _rememberLastAddress(_baseUrl ?? url);
  }

  /// Retire un compte du carnet et applique celui qui prend sa place.
  ///
  /// Passe par ici plutôt que par le registre directement : sans quoi le jeton
  /// du compte retiré resterait en mémoire du client, prêt à repartir dans une
  /// requête qui ne le concerne plus.
  Future<void> forgetAccount(String id) async {
    await servers.load();
    await servers.forget(id);
    await _applyActiveAccount();
  }

  /// Ferme la session du compte actif **sur cet appareil** et passe au suivant
  /// s'il y en a un. C'est ce qui fait qu'une déconnexion d'un serveur ne
  /// renvoie pas à l'écran de connexion tant qu'un autre compte tient.
  Future<void> clearAuth() async {
    await servers.load();
    final active = servers.active;
    if (active == null) {
      _token = null;
      return;
    }
    await servers.forget(active.id);
    await _applyActiveAccount();
  }

  // ==================== PROFIL EN CACHE ====================
  //
  // Le profil est relu au serveur à chaque démarrage, et c'est très bien tant
  // qu'il répond. Sans lui, l'app tombait sur l'écran de connexion — donc sur
  // rien du tout, alors que des médias téléchargés attendent sur le disque.
  // Cette copie est ce qui permet d'ouvrir une session hors ligne : la même
  // identité, les mêmes droits, jusqu'à ce que le serveur puisse confirmer ou
  // démentir.

  // Un profil **par compte** : hors ligne, l'app doit rouvrir l'identité du
  // serveur actif, pas celle du dernier auquel on s'est connecté.

  Future<void> cacheProfile(User user) async {
    try {
      final active = servers.active;
      if (active == null) return;
      await servers.writeProfile(active.id, jsonEncode(user.toJson()));
    } catch (_) {}
  }

  Future<User?> readCachedProfile() async {
    try {
      final active = servers.active;
      if (active == null) return null;
      final raw = await servers.readProfile(active.id);
      if (raw == null || raw.isEmpty) return null;
      return User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCachedProfile() async {
    try {
      final active = servers.active;
      if (active == null) return;
      await servers.clearProfile(active.id);
    } catch (_) {}
  }

  // ==================== AUTH API ====================

  /// Sign-up is closed unless the server has no account yet, in which case that
  /// first account becomes the owner. Otherwise [inviteToken] is required.
  Future<Map<String, dynamic>> register(
    String username,
    String password, {
    String? inviteToken,
  }) async {
    final response = await _dio.post("/api/auth/register", data: {
      "username": username,
      "password": password,
      if (inviteToken != null && inviteToken.isNotEmpty)
        "invite_token": inviteToken,
    });
    await saveLastUsername(username);
    return response.data as Map<String, dynamic>;
  }

  /// True while the server has no account at all: the login screen offers the
  /// sign-up form only then, or when an invitation token is in hand.
  /// Unauthenticated, and exposes nothing but that boolean.
  Future<bool> getSetupRequired() async {
    final response = await _dio.get("/api/auth/state");
    final data = response.data as Map<String, dynamic>;
    return data['setup_required'] == true;
  }

  // ==================== TV DEVICE PAIRING ====================

  /// Opens a pairing on behalf of a screen that cannot type a password.
  /// Unauthenticated server-side — that is the point.
  Future<DevicePairing> startDevicePairing({required String deviceName}) async {
    final response = await _dio.post(
      "/api/auth/device/start",
      data: {"device_name": deviceName},
    );
    return DevicePairing.fromJson(response.data as Map<String, dynamic>);
  }

  /// Asks whether a phone has approved yet. Returns the session on the one poll
  /// that finds it approved; the server drops the pairing at that point.
  Future<DevicePairingStatus> pollDevicePairing(String deviceCode) async {
    final response = await _dio.post(
      "/api/auth/device/poll",
      data: {"device_code": deviceCode},
    );
    return DevicePairingStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// Mints a session for another screen, under this account.
  ///
  /// The television it is destined for has never reached this server — that is
  /// the point of direct linking — so the phone asks on its behalf and carries
  /// the answer over the local network itself. A session of its own rather than
  /// a copy of this one: revoking the TV must not sign the phone out.
  Future<DeviceSession> createDeviceSession() async {
    final response = await _dio.post("/api/auth/device/session");
    return DeviceSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Describes a pending pairing to the phone about to approve it.
  Future<DevicePairingRequest> lookupDevicePairing(String userCode) async {
    final response = await _dio.get(
      "/api/auth/device/pending",
      queryParameters: {"code": userCode},
    );
    return DevicePairingRequest.fromJson(response.data as Map<String, dynamic>);
  }

  /// Binds a pending pairing to this account. The television inherits exactly
  /// the signed-in user, so this is the moment that matters.
  Future<void> approveDevicePairing(String userCode) async {
    await _dio.post("/api/auth/device/approve", data: {"user_code": userCode});
  }

  Future<void> denyDevicePairing(String userCode) async {
    await _dio.post("/api/auth/device/deny", data: {"user_code": userCode});
  }

  /// What the QR on the television encodes.
  ///
  /// Built from the address this client is connected to for the same reason the
  /// invitation link is: behind a proxy or a tunnel the server has no idea what
  /// its public address is, and the phone has to reach the same one the TV did.
  String devicePairingLink(String userCode) => "$baseUrl/?tv=$userCode";

  /// Adopts a session minted elsewhere — the pairing approval, in practice.
  /// Skips the login call entirely: there is no password to present.
  Future<void> adoptSession(
    String token, {
    required String username,
    int? userId,
  }) async {
    await rememberSession(
      serverUrl: baseUrl,
      username: username,
      token: token,
      userId: userId,
    );
  }

  Future<void> changeOwnPassword(
      String currentPassword, String newPassword) async {
    await _dio.post("/api/auth/password", data: {
      "current_password": currentPassword,
      "new_password": newPassword,
    });
  }

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

  // ==================== MEDIA API ====================

  /// Client apps (APK / DMG / EXE) embedded in the server image. Unauthenticated
  /// server-side, so this also works from the login screen.
  Future<List<AppDownload>> getAppDownloads() async {
    final response = await _dio.get("/api/downloads");
    return _parseDownloads(response.data as Map<String, dynamic>);
  }

  /// Absolute URL for an artifact, ready to hand to the browser or the shell.
  String getAppDownloadUrl(AppDownload download) {
    return "$baseUrl${download.url}";
  }

  /// Fetches an artifact to [savePath] for the in-app updater.
  ///
  /// On its own Dio on purpose: the shared client pins a 30 s receive timeout
  /// that a 150 MB installer trips on any slow link, and /api/downloads is
  /// unauthenticated so none of the interceptor's work is needed here.
  Future<void> downloadAppArtifact(
    AppDownload download,
    String savePath, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
    ));
    try {
      await dio.download(
        getAppDownloadUrl(download),
        savePath,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
      );
    } finally {
      dio.close();
    }
  }

  /// Replaces the installer of one platform (admin only). The platform is
  /// deduced server-side from the extension, so [filename] must keep it.
  ///
  /// Either [path] (desktop/mobile: streamed from disk) or [bytes] (web, where
  /// there is no file path) must be given. [onProgress] receives sent/total,
  /// total being -1 while the size is unknown.
  ///
  /// Returns the refreshed artifact list.
  Future<List<AppDownload>> uploadAppDownload({
    required String filename,
    String? path,
    List<int>? bytes,
    String? version,
    void Function(int sent, int total)? onProgress,
  }) async {
    final formData = FormData.fromMap({
      if (version != null && version.isNotEmpty) "version": version,
      "file": path != null
          ? await MultipartFile.fromFile(path, filename: filename)
          : MultipartFile.fromBytes(bytes ?? const [], filename: filename),
    });

    final response = await _dio.post(
      "/api/downloads",
      data: formData,
      onSendProgress: onProgress,
      // A 150 MB installer over a home connection outlives the default
      // timeouts, and the server answers only once the file is on disk.
      options: Options(
        sendTimeout: const Duration(minutes: 30),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    return _parseDownloads(response.data as Map<String, dynamic>);
  }

  /// Removes one published installer (admin only). Returns the refreshed list.
  Future<List<AppDownload>> deleteAppDownload(AppDownload download) async {
    final response = await _dio.delete("/api/downloads/${download.file}");
    return _parseDownloads(response.data as Map<String, dynamic>);
  }

  List<AppDownload> _parseDownloads(Map<String, dynamic> data) {
    return (data['artifacts'] as List<dynamic>? ?? const [])
        .map((e) => AppDownload.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<HomeResponse> getHome() async {
    final id = accountId;
    if (id != null) unawaited(mediaFailover.refreshIdentities(id));
    unawaited(_progressSync.synchronize());
    final response = await _dio.get("/api/home");
    return HomeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<HomeMediaItem>> getMovies() async {
    unawaited(_progressSync.synchronize());
    final response = await _dio.get("/api/movies");
    return (response.data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Media>> getShows() async {
    final response = await _dio.get("/api/shows");
    return (response.data as List<dynamic>)
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Media>> getShowSeasons(int showId) async {
    final response = await _dio.get("/api/shows/$showId/seasons");
    return (response.data as List<dynamic>)
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HomeMediaItem>> getSeasonEpisodes(int seasonId) async {
    await _progressSync.synchronize();
    final response = await _dio.get("/api/seasons/$seasonId/episodes");
    return (response.data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HomeMediaItem>> getShowSeasonEpisodes(
      int showId, int seasonNumber) async {
    await _progressSync.synchronize();
    final response =
        await _dio.get("/api/shows/$showId/seasons/$seasonNumber/episodes");
    return (response.data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ShowResumeResponse> getShowResumeEpisode(int showId) async {
    await _progressSync.synchronize();
    final response = await _dio.get("/api/shows/$showId/resume");
    return ShowResumeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  // ==================== PROGRESSION HEARTBEAT ====================

  Future<Map<String, dynamic>> getProgress(int mediaId) async {
    await _progressSync.synchronize();
    final response = await _dio.get("/api/progress", queryParameters: {
      "media_id": mediaId,
    });
    return response.data as Map<String, dynamic>;
  }

  /// [clientUpdatedAt] date une lecture qui a eu lieu avant l'envoi — le rejeu
  /// d'un visionnage hors ligne. Le serveur s'en sert pour ne pas écraser une
  /// progression plus récente venue d'un autre appareil ; un battement de coeur
  /// normal l'omet et vaut « maintenant ».
  Future<bool> sendProgress({
    required int mediaId,
    required int currentPositionSeconds,
    required int duration,
    required bool isFinished,
    DateTime? clientUpdatedAt,
  }) async {
    final sourceAccountId = accountId;
    final response = await _dio.post("/api/progress", data: {
      "media_id": mediaId,
      "current_position_seconds": currentPositionSeconds,
      "duration": duration,
      "is_finished": isFinished,
      if (clientUpdatedAt != null)
        "client_updated_at": clientUpdatedAt.toUtc().toIso8601String(),
    });

    unawaited(_progressSync.synchronize(
        force: true, sourceAccountId: sourceAccountId, mediaId: mediaId));
    return response.data["is_finished"] as bool? ?? isFinished;
  }

  Future<Map<String, dynamic>> setMediaWatched(
      int mediaId, bool watched) async {
    final sourceAccountId = accountId;
    final response = await _dio.post("/api/media/$mediaId/watched", data: {
      "watched": watched,
    });
    unawaited(_progressSync.synchronize(
        force: true, sourceAccountId: sourceAccountId, mediaId: mediaId));
    return response.data as Map<String, dynamic>;
  }

  Future<void> hideFromContinueWatching({int? movieId, int? showId}) async {
    final data = <String, dynamic>{};
    if (movieId != null) data['movie_id'] = movieId;
    if (showId != null) data['show_id'] = showId;
    await _dio.post('/api/continue-watching/hide', data: data);
  }

  // ==================== EPISODE NAVIGATION ====================

  Future<NextEpisodeResponse> getNextEpisode(int episodeId) async {
    final response = await _dio.get("/api/episodes/$episodeId/next");
    return NextEpisodeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<EpisodeTimestamps> getEpisodeTimestamps(int episodeId) async {
    final response = await _dio.get("/api/episodes/$episodeId/timestamps");
    return EpisodeTimestamps.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<VideoChapter>> getEpisodeChapters(int episodeId) async {
    final response = await _dio.get("/api/episodes/$episodeId/chapters");
    final data = response.data["chapters"] as List? ?? [];
    return data
        .map((json) => VideoChapter.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Fetches rich, Emby-style catalog details (cast, genres, rating, backdrop,
  /// crew…) for a movie or show, merging local library data with live TMDB.
  /// La fiche sous sa forme brute, telle que le téléchargement hors ligne la
  /// range sur le disque. Voir [getMediaTracksJson] pour le même raisonnement.
  Future<Map<String, dynamic>> getMediaDetailsJson(int mediaId) async {
    await _progressSync.synchronize();
    final response = await _dio.get("/api/media/$mediaId/details");
    return response.data as Map<String, dynamic>;
  }

  Future<MediaDetails> getMediaDetails(int mediaId) async {
    return MediaDetails.fromJson(await getMediaDetailsJson(mediaId));
  }

  /// Fetches an actor/crew profile with filmography (TMDB person id).
  Future<PersonDetails> getPersonDetails(int personTmdbId) async {
    final response = await _dio.get("/api/person/$personTmdbId");
    return PersonDetails.fromJson(response.data as Map<String, dynamic>);
  }

  /// Fetches a movie saga/collection with all its films (TMDB collection id).
  Future<CollectionDetails> getCollectionDetails(int collectionTmdbId) async {
    final response = await _dio.get("/api/collection/$collectionTmdbId");
    return CollectionDetails.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MediaTracks> getMediaTracks(int mediaId) async {
    return MediaTracks.fromJson(await getMediaTracksJson(mediaId));
  }

  /// Charge la liste des pistes sous sa forme brute.
  ///
  /// Le téléchargement hors ligne met cette réponse de côté telle quelle et la
  /// reparse sans serveur : la garder en JSON évite d'avoir à sérialiser
  /// [MediaTracks] en sens inverse, et la copie locale reste lisible par une
  /// version plus riche du modèle.
  Future<Map<String, dynamic>> getMediaTracksJson(int mediaId) async {
    final response = await _dio.get("/api/media/$mediaId/tracks");
    return response.data as Map<String, dynamic>;
  }

  Future<RequestCatalogPage> getRequestCatalog({
    required int page,
    required String type,
    String? query,
    RequestCatalogFilters filters = RequestCatalogFilters.defaults,
  }) async {
    final response = await _dio.get('/api/requests/catalog', queryParameters: {
      'page': page,
      'type': type,
      if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
      if (filters.hasDiscoverParams) ...filters.toQueryParams(),
    });
    return RequestCatalogPage.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<RequestGenre>> getRequestFilterGenres(String type) async {
    final response =
        await _dio.get('/api/requests/filter-options', queryParameters: {
      'type': type,
    });
    final genres = response.data['genres'] as List<dynamic>? ?? const [];
    return genres
        .map((e) => RequestGenre.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<RequestWatchProvider>> getRequestWatchProviders({
    required String type,
    required String region,
  }) async {
    final response =
        await _dio.get('/api/requests/watch-providers', queryParameters: {
      'type': type,
      'region': region,
    });
    final providers = response.data['providers'] as List<dynamic>? ?? const [];
    return providers
        .map((e) => RequestWatchProvider.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<RequestMediaDetails> getRequestMediaDetails(
      int tmdbId, RequestMediaType type) async {
    final response = await _dio.get(
      '/api/requests/media/$tmdbId',
      queryParameters: {'type': type.name},
    );
    return RequestMediaDetails.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<RequestEpisode>> getRequestSeasonEpisodes(
      int tmdbId, int seasonNumber) async {
    final response = await _dio.get(
      '/api/requests/media/$tmdbId/seasons/$seasonNumber/episodes',
    );
    final episodes = response.data['episodes'] as List<dynamic>? ?? const [];
    return episodes
        .map((item) => RequestEpisode.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> requestMedia(
    RequestMediaItem media, {
    List<int>? seasons,
  }) {
    return requestTmdbMedia(
      tmdbId: media.id,
      mediaType: media.mediaType.name,
      title: media.title,
      posterPath: media.posterPath,
      seasons: seasons,
    );
  }

  /// Sends a MediaHub request from anywhere a TMDB id is known — the requests
  /// catalog, the library show page, or the player's end-of-season card.
  Future<void> requestTmdbMedia({
    required int tmdbId,
    required String mediaType,
    required String title,
    String? posterPath,
    List<int>? seasons,
  }) async {
    await _dio.post('/api/requests', data: {
      'tmdbId': tmdbId,
      'mediaType': mediaType,
      'title': title,
      'posterPath': posterPath,
      if (seasons != null && seasons.isNotEmpty) 'seasons': seasons,
    });
  }

  // ==================== INDEXER API ====================

  Future<void> triggerScan() async {
    await _dio.post("/api/indexer/scan");
  }

  Future<void> triggerMetadataBackfill() async {
    await _dio.post("/api/indexer/metadata/backfill");
  }

  Future<void> triggerRedetectAllMatches() async {
    await _dio.post("/api/indexer/metadata/redetect-all");
  }

  /// Movies and shows that remain unidentified or have incomplete artwork/text.
  /// The server rebuilds this queue from its database on every request.
  Future<List<Media>> getMediaReviewQueue() async {
    final response = await _dio.get("/api/indexer/review");
    final data = response.data as Map<String, dynamic>;
    final items = data["items"] as List? ?? const [];
    return items
        .map((e) => Media.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Fetches TMDB poster/overview for a single movie or show.
  Future<Media> enrichMediaMetadata(int mediaId) async {
    final response = await _dio.post("/api/media/$mediaId/metadata/enrich");
    return Media.fromJson(response.data as Map<String, dynamic>);
  }

  Future<Media> redetectMediaMetadata(int mediaId) async {
    final response = await _dio.post("/api/media/$mediaId/metadata/redetect");
    return Media.fromJson(response.data as Map<String, dynamic>);
  }

  /// Re-identifies a movie/show against TMDB to fix a wrong match. Provide a
  /// [title] to search for, or a [tmdbId] to force an exact entry.
  Future<Media> rematchMediaMetadata(
    int mediaId, {
    String? title,
    int? tmdbId,
  }) async {
    final response = await _dio.post(
      "/api/media/$mediaId/metadata/rematch",
      queryParameters: {
        if (title != null && title.trim().isNotEmpty) "title": title.trim(),
        if (tmdbId != null && tmdbId > 0) "tmdb_id": tmdbId,
      },
    );
    return Media.fromJson(response.data as Map<String, dynamic>);
  }

  /// Search TMDB manually for the "fix metadata" poster picker.
  Future<List<TmdbCandidate>> searchTmdb(
    String query, {
    MediaType type = MediaType.movie,
  }) async {
    final response = await _dio.get(
      "/api/tmdb/search",
      queryParameters: {
        "query": query.trim(),
        "type": type == MediaType.show ? "show" : "movie",
      },
    );
    final results = response.data["results"] as List? ?? [];
    return results
        .map((e) => TmdbCandidate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> triggerSubtitleExtract() async {
    await _dio.post("/api/indexer/subtitles/extract");
  }

  /// Extract subtitles for a single movie or episode.
  ///
  /// [force] (default) re-extracts everything — used by the manual button.
  /// When [force] is false the server only extracts if nothing is registered
  /// yet, which is the cheap "ensure" path used in the background on playback.
  Future<List<MediaSubtitleTrack>> forceMediaSubtitleExtract(
    int mediaId, {
    bool force = true,
  }) async {
    final response = await _dio.post(
      "/api/media/$mediaId/subtitles/extract",
      queryParameters: force ? null : {"force": "false"},
    );
    final subs = response.data["subtitles"] as List? ?? [];
    return subs
        .map((e) => MediaSubtitleTrack.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<IndexerStatus> getIndexerStatus() async {
    final response = await _dio.get("/api/indexer/status");
    return IndexerStatus.fromJson(response.data as Map<String, dynamic>);
  }

  Future<bool> getScanStatus() async {
    final status = await getIndexerStatus();
    return status.isScanning;
  }

  // ==================== SERVER SETTINGS ====================

  Future<ServerSettings> getServerSettings() async {
    final response = await _dio.get('/api/settings');
    return ServerSettings.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ServerSettings> updateServerSettings({
    String? mediaHubUrl,
    String? mediaHubApiKey,
    bool clearMediaHubApiKey = false,
    String? tmdbApiKey,
    bool clearTmdbApiKey = false,
    String? tmdbLanguage,
    String? moviesDir,
    String? seriesDir,
  }) async {
    final response = await _dio.put('/api/settings', data: {
      if (mediaHubUrl != null) 'mediahub_url': mediaHubUrl,
      if (mediaHubApiKey != null) 'mediahub_api_key': mediaHubApiKey,
      if (clearMediaHubApiKey) 'clear_mediahub_api_key': true,
      if (tmdbApiKey != null) 'tmdb_api_key': tmdbApiKey,
      if (clearTmdbApiKey) 'clear_tmdb_api_key': true,
      if (tmdbLanguage != null) 'tmdb_language': tmdbLanguage,
      if (moviesDir != null) 'movies_dir': moviesDir,
      if (seriesDir != null) 'series_dir': seriesDir,
    });
    return ServerSettings.fromJson(response.data as Map<String, dynamic>);
  }

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

/// Public server settings from GET/PUT /api/settings (secrets are never cleartext).
class ServerSettings {
  final String mediaHubUrl;
  final bool mediaHubApiKeySet;
  final String? mediaHubApiKeyHint;
  final bool tmdbApiKeySet;
  final String? tmdbApiKeyHint;
  final String tmdbLanguage;
  final String moviesDir;
  final String seriesDir;

  ServerSettings({
    required this.mediaHubUrl,
    required this.mediaHubApiKeySet,
    this.mediaHubApiKeyHint,
    required this.tmdbApiKeySet,
    this.tmdbApiKeyHint,
    required this.tmdbLanguage,
    required this.moviesDir,
    required this.seriesDir,
  });

  factory ServerSettings.fromJson(Map<String, dynamic> json) {
    return ServerSettings(
      mediaHubUrl: json['mediahub_url'] as String? ?? '',
      mediaHubApiKeySet: json['mediahub_api_key_set'] as bool? ?? false,
      mediaHubApiKeyHint: json['mediahub_api_key_hint'] as String?,
      tmdbApiKeySet: json['tmdb_api_key_set'] as bool? ?? false,
      tmdbApiKeyHint: json['tmdb_api_key_hint'] as String?,
      tmdbLanguage: json['tmdb_language'] as String? ?? 'fr-FR',
      moviesDir: json['movies_dir'] as String? ?? '',
      seriesDir: json['series_dir'] as String? ?? '',
    );
  }
}

/// Combined indexer / subtitle-extraction status from the server.
class IndexerStatus {
  final bool isScanning;
  final bool isBackfillingMetadata;
  final bool isRedetectingAll;
  final RedetectAllProgress redetectAll;
  final bool isExtractingSubtitles;
  final SubtitleExtractionStats subtitleExtraction;

  IndexerStatus({
    required this.isScanning,
    required this.isBackfillingMetadata,
    required this.isRedetectingAll,
    required this.redetectAll,
    required this.isExtractingSubtitles,
    required this.subtitleExtraction,
  });

  factory IndexerStatus.fromJson(Map<String, dynamic> json) {
    return IndexerStatus(
      isScanning: json["is_scanning"] as bool? ?? false,
      isBackfillingMetadata: json["is_backfilling_metadata"] as bool? ?? false,
      isRedetectingAll: json["is_redetecting_all"] as bool? ?? false,
      redetectAll: RedetectAllProgress.fromJson(
        json["redetect_all"] as Map<String, dynamic>? ?? {},
      ),
      isExtractingSubtitles: json["is_extracting_subtitles"] as bool? ?? false,
      subtitleExtraction: SubtitleExtractionStats.fromJson(
        json["subtitle_extraction"] as Map<String, dynamic>? ?? {},
      ),
    );
  }

  bool get isBusy =>
      isScanning ||
      isBackfillingMetadata ||
      isRedetectingAll ||
      isExtractingSubtitles;
}

class RedetectAllProgress {
  final int total;
  final int processed;
  final int updated;
  final int skipped;

  RedetectAllProgress({
    this.total = 0,
    this.processed = 0,
    this.updated = 0,
    this.skipped = 0,
  });

  factory RedetectAllProgress.fromJson(Map<String, dynamic> json) {
    return RedetectAllProgress(
      total: json["total"] as int? ?? 0,
      processed: json["processed"] as int? ?? 0,
      updated: json["updated"] as int? ?? 0,
      skipped: json["skipped"] as int? ?? 0,
    );
  }
}

class SubtitleExtractionStats {
  final int total;
  final int processed;
  final int succeeded;
  final int failed;
  final int tracks;

  SubtitleExtractionStats({
    this.total = 0,
    this.processed = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.tracks = 0,
  });

  factory SubtitleExtractionStats.fromJson(Map<String, dynamic> json) {
    return SubtitleExtractionStats(
      total: json["total"] as int? ?? 0,
      processed: json["processed"] as int? ?? 0,
      succeeded: json["succeeded"] as int? ?? 0,
      failed: json["failed"] as int? ?? 0,
      tracks: json["tracks"] as int? ?? 0,
    );
  }
}
