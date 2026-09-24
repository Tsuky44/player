import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_download.dart';
import '../models/device_pairing.dart';
import '../models/server_account.dart';
import 'client_identity.dart';
import 'client_log.dart';
import 'playback_capabilities.dart';
import 'playback_access.dart';

import 'server_registry.dart';
import 'media_failover.dart';
import '../models/media_request.dart';
import '../models/media_share.dart';
import '../models/server_activity.dart';
import '../models/remote_playback.dart';
import '../utils/app_platform.dart';
import '../models/request_catalog_filters.dart';
import '../models/models.dart';
import '../models/player_layout.dart';
import '../models/player_layout_preset.dart';
import 'conditional_get.dart';
import 'api_types.dart';
import 'hls_session.dart';

// Le descripteur de session a quitté ce fichier ; ses appelants l'importaient
// d'ici et continuent de le faire.
export 'hls_session.dart';
export 'api_types.dart';

part 'api/account_admin.dart';
part 'api/watch_party.dart';
part 'api/library_admin.dart';
part 'api/activity.dart';
part 'api/player_layouts.dart';
part 'api/media_shares.dart';
part 'api/shared_link_client.dart';

class _PlaybackRequestScope {
  const _PlaybackRequestScope(this.origin, this.authorization);
  final String origin;
  final String? authorization;
}

class ApiClient
    with
        _AccountAdminEndpoints,
        _WatchPartyEndpoints,
        _LibraryAdminEndpoints,
        _ActivityEndpoints,
        _PlayerLayoutEndpoints,
        _MediaShareEndpoints {
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

  @override
  final Dio _dio;

  /// Les serveurs auxquels cet appareil a un compte. Le client ne détient plus
  /// « une » adresse et « un » jeton : il applique ceux du compte actif, et
  /// changer de serveur revient à en désigner un autre. Voir ADR-0013.
  final ServerRegistry servers;
  late final MediaFailover mediaFailover = MediaFailover(servers);

  /// Les listes de la médiathèque, relues seulement quand elles changent.
  final ConditionalGetCache _libraryLists = ConditionalGetCache();
  String? _pinnedAccountId;
  String? get accountId => _pinnedAccountId ?? servers.active?.id;

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

  ApiClient({ServerRegistry? registry, Dio? httpClient})
      : servers = registry ?? ServerRegistry(),
        _dio = httpClient ?? Dio() {
    _dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (!_configLoaded) {
        await _loadConfig();
      }
      final scope = options.extra['playbackScope'] as _PlaybackRequestScope?;
      options.baseUrl = scope?.origin ?? _baseUrl ?? _defaultBaseUrl;

      // Le jeton envoyé est celui du compte actif, et rien d'autre : pointer
      // le client sur une autre adresse le met à nul plutôt que de présenter
      // à un serveur la session ouverte sur un autre.
      final authToken = options.extra['playbackMedia'] == true
          ? null
          : scope != null
              ? scope.authorization
              : _token;
      if (authToken != null) {
        options.headers["Authorization"] = "Bearer $authToken";
      } else {
        options.headers.remove('Authorization');
      }

      // Ce que cet appareil annonce de lui-même : son nom et son application,
      // pour la liste des appareils connectés et le tableau de bord.
      options.headers.addAll(ClientIdentity.headers);

      options.connectTimeout = const Duration(seconds: 10);
      options.receiveTimeout = const Duration(seconds: 30);

      return handler.next(options);
    }, onResponse: (response, handler) {
      if (_pinnedAccountId == null || _pinnedAccountId == servers.active?.id) {
        onConnectionSuccess?.call();
      }
      return handler.next(response);
    }, onError: (DioException e, handler) {
      // Global error logging
      ClientLog.error(
          "API Error [${e.requestOptions.method}] ${redactPlaybackDiagnostic(e.requestOptions.path)}: ${e.type.name} (${e.response?.statusCode ?? '-'})");
      switch (e.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
          if (_pinnedAccountId == null ||
              _pinnedAccountId == servers.active?.id) {
            onConnectionError?.call();
          }
        default:
          // Une réponse, même 500, prouve qu'il y a quelqu'un en face.
          if (e.response != null &&
              (_pinnedAccountId == null ||
                  _pinnedAccountId == servers.active?.id)) {
            onConnectionSuccess?.call();
          }
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

  // ==================== COMPTES LIÉS (ADR-0017) ====================
  //
  // Les liens vivent sur les serveurs, et ce sont eux qui se transmettent la
  // progression. L'app ne fait plus que deux choses : présenter à chaque
  // serveur le jeton qui est le sien — jamais celui d'un autre — et relire les
  // liens pour les afficher et savoir vers qui se tourner en cas de panne.

  /// Un client lié à un compte du carnet, quel que soit le compte actif.
  Future<Dio?> _accountClient(String id) async {
    final account = servers.accountById(id);
    final token = await servers.tokenFor(id);
    if (account == null || token == null || token.isEmpty) return null;
    return _clientFactory(BaseOptions(
      baseUrl: account.url,
      headers: {'Authorization': 'Bearer $token'},
      followRedirects: false,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 10),
    ));
  }

  @visibleForTesting
  Dio Function(BaseOptions) clientFactory = (options) => Dio(options);
  Dio Function(BaseOptions) get _clientFactory => clientFactory;

  Future<void>? _refreshingLinks;

  /// Relit les liens de chaque compte du carnet et l'identité de son serveur.
  /// Un serveur injoignable garde ses liens connus : c'est précisément quand
  /// il ne répond plus que le relais de lecture en a besoin.
  Future<void> refreshAccountLinks() {
    return _refreshingLinks ??= _refreshAccountLinks().whenComplete(() {
      _refreshingLinks = null;
    });
  }

  Future<void> _refreshAccountLinks() async {
    await servers.load();
    await Future.wait(servers.accounts.map((account) async {
      final client = await _accountClient(account.id);
      if (client == null) return;
      try {
        if (account.serverId == null) {
          try {
            final info = await client.get('/api/federation/info');
            final serverId = (info.data as Map?)?['server_id'] as String?;
            if (serverId != null && serverId.isNotEmpty) {
              await servers.setServerId(account.id, serverId);
            }
          } on Object {/* Serveur ancien ou injoignable. */}
        }
        final response = await client.get('/api/links');
        final links = (response.data as List)
            .map((e) => AccountLink.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        await servers.setServerLinks(account.id, links);
      } on Object {
        // Hors ligne, session expirée ou serveur d'une version précédente.
      } finally {
        client.close();
      }
    }));
    await _migrateDeviceLinks();
    for (final account in servers.accounts) {
      unawaited(mediaFailover.refreshIdentities(account.id));
    }
  }

  /// Les versions précédentes gardaient les liens sur l'appareil. Ils sont
  /// remontés une fois aux serveurs, puis oubliés quand tous ont abouti.
  Future<void> _migrateDeviceLinks() async {
    final groups = servers.legacyLinkGroups;
    if (groups.isEmpty) return;
    var complete = true;
    for (final group in groups) {
      final ids = group.where((id) => servers.accountById(id) != null).toList();
      for (final other in ids.skip(1)) {
        if (servers.linkedAccounts(ids.first).any((a) => a.id == other)) {
          continue;
        }
        try {
          await linkAccounts(ids.first, other, refresh: false);
        } on Object {
          complete = false;
        }
      }
    }
    if (complete) await servers.clearLegacyLinks();
  }

  /// Lie le compte [fromId] au compte [toId]. Le serveur de [toId] émet un
  /// code qui prouve qu'on détient ce compte ; le serveur de [fromId] le
  /// présente lui-même à l'autre. Aucun jeton ne passe d'un serveur à l'autre.
  ///
  /// Le lien est en attente tant que les administrateurs des deux serveurs
  /// n'ont pas accepté la paire — une seule fois pour ces deux serveurs.
  Future<AccountLink> linkAccounts(String fromId, String toId,
      {bool refresh = true}) async {
    final from = servers.accountById(fromId);
    final to = servers.accountById(toId);
    if (from == null || to == null || fromId == toId) {
      throw StateError('Compte indisponible');
    }
    final toClient = await _accountClient(toId);
    final fromClient = await _accountClient(fromId);
    if (toClient == null || fromClient == null) {
      toClient?.close();
      fromClient?.close();
      throw StateError('Session expirée : reconnectez-vous à ce serveur.');
    }
    try {
      final code = await toClient.post('/api/links/code');
      final response = await fromClient.post('/api/links', data: {
        'url': to.url,
        'self_url': from.url,
        'code': (code.data as Map)['code'],
      });
      final link =
          AccountLink.fromJson(Map<String, dynamic>.from(response.data as Map));
      if (refresh) await refreshAccountLinks();
      return link;
    } finally {
      toClient.close();
      fromClient.close();
    }
  }

  /// Dissocie un lien déclaré par le serveur du compte [accountId]. Les deux
  /// serveurs arrêtent de se transmettre la progression ; l'historique déjà
  /// partagé reste de chaque côté.
  Future<void> unlinkAccount(String accountId, AccountLink link) async {
    final client = await _accountClient(accountId);
    if (client == null) throw StateError('Session expirée');
    try {
      await client.delete('/api/links/${link.id}');
    } finally {
      client.close();
    }
    await refreshAccountLinks();
  }

  // Côté administrateur : les serveurs liés au serveur actif.

  Future<List<PeerServer>> getPeerServers() async {
    final response = await _dio.get('/api/peers');
    return (response.data as List)
        .map((e) => PeerServer.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<PeerServer> approvePeerServer(int id) async {
    final response = await _dio.post('/api/peers/$id/approve');
    return PeerServer.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  Future<PeerServer> updatePeerServerUrl(int id, String url) async {
    final response = await _dio.put('/api/peers/$id', data: {'url': url});
    return PeerServer.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  Future<void> removePeerServer(int id) async {
    await _dio.delete('/api/peers/$id');
  }

  // Get current active base URL
  @override
  String get baseUrl => _baseUrl ?? _defaultBaseUrl;

  /// Vrai pour le visiteur d'un lien de partage, qui n'a pas de compte
  /// ([SharedLinkApiClient]) : le lecteur n'offre alors rien qui en suppose un.
  bool get isGuest => false;

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
  String getStreamUrl(int mediaId, {PlaybackAccess? access}) {
    if (access != null && access.mediaId != mediaId) {
      throw StateError('Média différent du ticket');
    }
    final url = "${access?.origin ?? baseUrl}/stream?media_id=$mediaId";
    return access?.protect(url) ?? url;
  }

  Future<PlaybackAccess> openPlaybackAccess(int mediaId) async {
    if (!_configLoaded) await _loadConfig();
    final scope = _PlaybackRequestScope(baseUrl, _token);
    Options scoped(String method) => Options(
        method: method,
        followRedirects: false,
        extra: {'playbackScope': scope});
    Response<dynamic> response;
    try {
      response = await _dio.request('/api/playback/tickets',
          data: {'media_id': mediaId}, options: scoped('POST'));
    } on DioException catch (error) {
      if (error.response?.statusCode != 404 &&
          error.response?.statusCode != 405) {
        rethrow;
      }
      // A missing media on a new server also returns 404. Only an explicit
      // legacy ping permits old public URLs; auth/timeouts never do.
      final ping = await _dio.request('/api/ping', options: scoped('GET'));
      final data = ping.data;
      if (data is! Map ||
          data['status'] != 'ok' ||
          data.containsKey('playback_ticket_version')) {
        rethrow;
      }
      return PlaybackAccess(
          origin: scope.origin,
          mediaId: mediaId,
          token: null,
          expiresAt: null,
          renew: () async => DateTime.now(),
          revoke: () async {});
    }
    final data = response.data as Map<String, dynamic>;
    final token = data['ticket'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw StateError('Ticket de lecture invalide');
    }
    return PlaybackAccess(
      origin: scope.origin,
      mediaId: mediaId,
      token: token,
      expiresAt: DateTime.parse(data['expires_at'] as String),
      renew: () async {
        final result = await _dio.request('/api/playback/tickets',
            data: {'ticket': token}, options: scoped('PUT'));
        return DateTime.parse(result.data['expires_at'] as String);
      },
      revoke: () async {
        await _dio.request('/api/playback/tickets',
            data: {'ticket': token}, options: scoped('DELETE'));
      },
    );
  }

  // HLS session destroy URL (to notify server on stop)
  String getHlsDestroyUrl(int mediaId, String sessionId,
      {PlaybackAccess? access}) {
    final url =
        "${access?.origin ?? baseUrl}/api/v1/stream/$mediaId/$sessionId";
    return access?.protect(url) ?? url;
  }

  /// URL of an external WebVTT subtitle for a given language. [start] shifts the
  /// timeline to match an HLS stream that begins at an offset; Direct Play uses 0.
  String getSubtitleUrl(int mediaId, String lang,
      {int start = 0, PlaybackAccess? access}) {
    // URL ends in ".vtt" so libmpv/media_kit detects the WebVTT parser from the
    // extension; without it the external track silently fails to load.
    final url =
        "${access?.origin ?? baseUrl}/api/v1/media/$mediaId/subtitles/${Uri.encodeComponent(lang)}.vtt?start=$start";
    return access?.protect(url) ?? url;
  }

  /// Spacing of the timeline stills for a media, as JSON. Also what starts the
  /// server filling them in, which is why the player only calls it once the
  /// first frame is on screen.
  Future<Map<String, dynamic>> openTimelinePreviews(int mediaId,
      {required PlaybackAccess access}) async {
    final response = await _dio.post(
      access.protect("${access.origin}/api/v1/media/$mediaId/previews"),
      options: Options(extra: {'playbackMedia': true}),
    );
    return response.data as Map<String, dynamic>;
  }

  /// One timeline still, as JPEG bytes.
  Future<Uint8List> fetchTimelinePreview(int mediaId, int index,
      {required PlaybackAccess access}) async {
    final response = await _dio.get<List<int>>(
      access.protect("${access.origin}/api/v1/media/$mediaId/previews/$index.jpg"),
      options: Options(
          responseType: ResponseType.bytes, extra: {'playbackMedia': true}),
    );
    final data = response.data;
    if (data == null || data.isEmpty) throw StateError('Empty preview');
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  /// Download the raw WebVTT text for a subtitle. Fetching it ourselves and
  /// injecting via SubtitleTrack.data() is far more reliable than asking mpv to
  /// fetch a URL while it is already busy pulling an HLS stream.
  Future<String> fetchSubtitleContent(int mediaId, String lang,
      {int start = 0, PlaybackAccess? access}) async {
    final lease = access ?? await openPlaybackAccess(mediaId);
    try {
      final response = await _dio.get<String>(
        getSubtitleUrl(mediaId, lang, start: start, access: lease),
        options: Options(
            responseType: ResponseType.plain, extra: {'playbackMedia': true}),
      );
      return response.data ?? "";
    } finally {
      if (access == null) await lease.close();
    }
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
    PlaybackAccess? access,
    PlaybackCapabilities? capabilities,
  }) async {
    final stopwatch = Stopwatch()..start();
    final response = await _dio.post(
      "${access?.origin ?? baseUrl}/api/v1/stream/$mediaId/start",
      options: Options(extra: {'playbackMedia': true}),
      queryParameters: {
        "quality": quality,
        "start": startSeconds,
        "audio": audioIndex,
        // Bitmap subtitles have no out-of-band form, so the transcoder paints
        // the chosen one into the video. -1 means none.
        "burnsub": burnSubtitleIndex,
        // Ce client rouvre une session pour reculer au-delà de ce qu'elle a
        // gardé (retain_seconds) : le serveur peut effacer le reste.
        "purge": 1,
        ...?access?.query,
        // What this device can decode and play back. Without it the server
        // assumes the weakest client it has ever had to serve — H.264 8-bit and
        // stereo AAC — and re-encodes a file this one could have taken as it is.
        // Celles du moteur qui lira la session quand ce n'est pas celui de
        // l'appareil — AVPlayer à côté de mpv sur iPhone et Mac (ADR-0035).
        ...(capabilities ?? PlaybackCapabilitiesResolver.current)
            .toQueryParameters(),
      },
    );
    stopwatch.stop();
    final session = HlsSession.fromJson(response.data as Map<String, dynamic>);
    // A returned URL must remain on the issuing origin. The server supplies
    // the URL, but it must not accidentally send its ticket to another host.
    if (access != null) access.protect(session.masterUrl);
    // Logs both what was ASKED (startSeconds) and what the server CONFIRMS
    // (session.startOffset) side by side — the fastest way to tell whether a
    // seek landing at the wrong position is a client bug (mismatch here) or
    // something downstream (the two agree, but playback still drifts).
    debugPrint(
        "ApiClient: startHlsSession took ${stopwatch.elapsedMilliseconds}ms "
        "for media $mediaId quality $quality audio $audioIndex "
        "requestedStart=${startSeconds}s confirmedStart=${session.startOffset}s "
        "video=${session.videoMode}"
        "${session.videoReason.isEmpty ? '' : ' (${session.videoReason})'} "
        "session=${session.sessionId}");
    return session;
  }

  // Notify server to destroy an HLS transcoding session (kills FFmpeg + temp files)
  Future<void> destroyHlsSession(int mediaId, String sessionId,
      {PlaybackAccess? access}) async {
    if (sessionId.isEmpty) return;
    try {
      await _dio.delete(getHlsDestroyUrl(mediaId, sessionId, access: access),
          options: Options(extra: {'playbackMedia': true}));
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
  @override
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
    if (synchronize) unawaited(refreshAccountLinks());
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
  @override
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
    final response = await _dio.get("/api/home");
    return HomeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<HomeMediaItem>> getMovies() async {
    final data =
        await _libraryLists.get(_dio, "/api/movies", scope: accountId ?? '');
    return (data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Media>> getShows() async {
    final data =
        await _libraryLists.get(_dio, "/api/shows", scope: accountId ?? '');
    return (data as List<dynamic>)
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
    final response = await _dio.get("/api/seasons/$seasonId/episodes");
    return (response.data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HomeMediaItem>> getShowSeasonEpisodes(
      int showId, int seasonNumber) async {
    final response =
        await _dio.get("/api/shows/$showId/seasons/$seasonNumber/episodes");
    return (response.data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ShowResumeResponse> getShowResumeEpisode(int showId) async {
    final response = await _dio.get("/api/shows/$showId/resume");
    return ShowResumeResponse.fromJson(response.data as Map<String, dynamic>);
  }

  // ==================== PROGRESSION HEARTBEAT ====================

  Future<Map<String, dynamic>> getProgress(int mediaId) async {
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
    final response = await _dio.post("/api/progress", data: {
      "media_id": mediaId,
      "current_position_seconds": currentPositionSeconds,
      "duration": duration,
      "is_finished": isFinished,
      if (clientUpdatedAt != null)
        "client_updated_at": clientUpdatedAt.toUtc().toIso8601String(),
    });

    return response.data["is_finished"] as bool? ?? isFinished;
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

  /// Fetches rich catalog details (cast, genres, rating, backdrop,
  /// crew…) for a movie or show, merging local library data with live TMDB.
  /// La fiche sous sa forme brute, telle que le téléchargement hors ligne la
  /// range sur le disque. Voir [getMediaTracksJson] pour le même raisonnement.
  Future<Map<String, dynamic>> getMediaDetailsJson(int mediaId) async {
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

}
