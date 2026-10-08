import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../utils/app_platform.dart';
import 'hls_playlist.dart';

/// Les premières secondes d'une session HLS, téléchargées avant que le moteur
/// ne l'ouvre (ADR-0056).
///
/// Changer de source vide le tampon du moteur : la nouvelle part de zéro, et
/// sur une ligne lente — la raison même du changement — l'image reste figée le
/// temps d'en recevoir assez. Mesuré sur une ligne à 5 Mbit/s : 3,3 s d'écran
/// figé pour passer à un barreau à 3,5 Mbit/s, alors que l'ancienne source
/// avait encore sept secondes en mémoire.
///
/// Ces secondes-là servent ici : pendant que l'ancienne source joue ce qu'elle
/// a déjà reçu, [warm] télécharge le début de la nouvelle. Le moteur l'ouvre
/// ensuite par [masterUrl], une adresse de la boucle locale où ces segments
/// l'attendent ; tout le reste de la session passe par le même relais, qui le
/// demande au serveur tel quel.
///
/// Sous Windows et Linux seulement : c'est là que mpv lit, et là que ce relais
/// a été essayé. Ailleurs [open] rend null et le moteur ouvre la session
/// directement.
class HlsPreload {
  HlsPreload._(this._upstream, this._key, this._port);

  static HttpServer? _server;
  static final Map<String, HlsPreload> _sessions = {};
  static final HttpClient _client = HttpClient()..autoUncompress = false;

  /// Le dossier de la session chez le serveur, et sa requête (le ticket).
  final Uri _upstream;
  final String _key;
  final int _port;

  /// Les fichiers déjà reçus, par nom. Un fichier servi quitte la mémoire.
  final Map<String, Uint8List> _cache = {};
  final Set<String> _fetched = {};

  /// Les téléchargements d'avance en cours. Le moteur qui demande l'un de ces
  /// fichiers l'attend ici plutôt que d'en lancer un second : mesuré, deux
  /// téléchargements du même segment sur une ligne lente, c'est 3,4 s d'image
  /// figée au lieu d'aucune.
  final Map<String, Future<Uint8List?>> _arriving = {};
  double _readySeconds = 0;
  bool _closed = false;

  /// Combien de fichiers le moteur a reçus d'ici plutôt que du serveur.
  int _served = 0;

  /// Ce que la session a déjà en mémoire, en secondes de film.
  double get readySeconds => _readySeconds;

  /// L'adresse à donner au moteur à la place de celle du serveur.
  String get masterUrl => Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _port,
        path: '/$_key/${_upstream.pathSegments.last}',
        query: _upstream.hasQuery ? _upstream.query : null,
      ).toString();

  /// Prépare le relais pour la session publiée à [masterUrl], ou rend null
  /// quand il n'a pas lieu d'être ici.
  static Future<HlsPreload?> open(String masterUrl) async {
    if (!AppPlatform.isWindows && !AppPlatform.isLinux) return null;
    final upstream = Uri.tryParse(masterUrl);
    if (upstream == null || upstream.pathSegments.isEmpty) return null;
    try {
      final server = _server ??= await _start();
      final random = Random.secure();
      final key = List.generate(16, (_) => random.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      return _sessions[key] = HlsPreload._(upstream, key, server.port);
    } catch (e) {
      // Sans relais, le moteur ouvre la session lui-même : plus lent au
      // changement, jamais cassé.
      debugPrint('HlsPreload: relais indisponible (${e.runtimeType})');
      return null;
    }
  }

  static Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_route(request)));
    return server;
  }

  static Future<void> _route(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final session = segments.length == 2 ? _sessions[segments[0]] : null;
    if (session == null || request.method != 'GET') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    await session._serve(request, segments[1]);
  }

  Uri _upstreamFor(String file, {String? query, bool warming = false}) {
    final q = query ?? (_upstream.hasQuery ? _upstream.query : '');
    // `warm=1` : le serveur sait que ce segment est pris d'avance, et ne
    // tient pas encore la session pour lue.
    final joined = [if (q.isNotEmpty) q, if (warming) 'warm=1'].join('&');
    return _upstream.resolve(file).replace(
        query: joined.isEmpty ? null : joined);
  }

  Future<void> _serve(HttpRequest request, String file) async {
    final response = request.response;
    try {
      var cached = _cache.remove(file);
      final arriving = _arriving[file];
      if (cached == null && arriving != null) {
        await arriving;
        cached = _cache.remove(file);
      }
      if (cached != null) {
        _served++;
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = _typeOf(file)
          ..headers.contentLength = cached.length
          ..add(cached);
        await response.close();
        return;
      }
      final upstream = await _client.getUrl(
          _upstreamFor(file, query: request.uri.hasQuery ? request.uri.query : ''));
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) upstream.headers.set(HttpHeaders.rangeHeader, range);
      final answer = await upstream.close();
      response.statusCode = answer.statusCode;
      for (final name in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.retryAfterHeader,
      ]) {
        final value = answer.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      if (answer.contentLength >= 0) {
        response.headers.contentLength = answer.contentLength;
      }
      await response.addStream(answer);
      await response.close();
    } catch (_) {
      // Le moteur a refermé la connexion, ou le serveur ne répond plus : le
      // moteur le verra comme il aurait vu la panne sans relais.
      try {
        await response.close();
      } catch (_) {
        // Déjà fermée.
      }
    }
  }

  /// Télécharge le début de la session jusqu'à avoir [seconds] de film, ou
  /// jusqu'à [budget]. Ce qui est arrivé reste acquis.
  Future<void> warm({double seconds = 6, required Duration budget}) async {
    final deadline = DateTime.now().add(budget);
    bool live() => !_closed && DateTime.now().isBefore(deadline);
    try {
      final masterName = _upstream.pathSegments.last;
      final masterBytes = await _download(masterName, deadline);
      if (masterBytes == null) return;
      final master = parseHlsMaster(String.fromCharCodes(masterBytes));
      final video = master.video;
      if (video == null) return;
      // La playlist maîtresse ne change pas : le moteur la reçoit d'ici.
      _cache[masterName] = masterBytes;

      while (live() && _readySeconds < seconds) {
        // Le son d'abord : il ne pèse rien, et ce qui est compté prêt l'est
        // alors pour l'image et pour lui.
        final audio = master.audio;
        if (audio != null) await _warmPlaylist(audio, seconds, deadline);
        if (!live()) return;
        final ready = await _warmPlaylist(video, seconds, deadline);
        if (ready == null) return;
        _readySeconds = ready;
        if (ready < seconds && live()) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    } catch (_) {
      // Une avance incomplète reste une avance.
    }
  }

  /// Télécharge les segments de [playlistUri] qui couvrent [seconds], et rend
  /// la durée ainsi en mémoire.
  Future<double?> _warmPlaylist(
      String playlistUri, double seconds, DateTime deadline) async {
    final uri = Uri.parse(playlistUri);
    final name = uri.pathSegments.last;
    final bytes = await _download(name, deadline,
        query: uri.hasQuery ? uri.query : null, warming: false);
    if (bytes == null) return null;
    final playlist = parseHlsMediaPlaylist(String.fromCharCodes(bytes));
    final init = playlist.initUri;
    if (init != null && !await _keep(init, deadline)) return 0;
    var ready = 0.0;
    for (final segment in playlist.segments) {
      if (ready >= seconds) break;
      if (!await _keep(segment.uri, deadline)) break;
      ready += segment.duration;
    }
    return ready;
  }

  /// Garde en mémoire le fichier désigné par [reference], s'il n'y est pas.
  Future<bool> _keep(String reference, DateTime deadline) async {
    final uri = Uri.parse(reference);
    final name = uri.pathSegments.last;
    if (_fetched.contains(name)) return true;
    final download = _download(name, deadline,
        query: uri.hasQuery ? uri.query : null, warming: true);
    _arriving[name] = download;
    final bytes = await download;
    if (bytes != null) {
      _fetched.add(name);
      _cache[name] = bytes;
    }
    _arriving.remove(name);
    return bytes != null;
  }

  Future<Uint8List?> _download(String file, DateTime deadline,
      {String? query, bool warming = false}) async {
    final left = deadline.difference(DateTime.now());
    if (_closed || left <= Duration.zero) return null;
    try {
      final request = await _client
          .getUrl(_upstreamFor(file, query: query, warming: warming))
          .timeout(left);
      final answer = await request.close().timeout(left);
      if (answer.statusCode != HttpStatus.ok) {
        await answer.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await answer.forEach(builder.add).timeout(left);
      return builder.takeBytes();
    } catch (_) {
      // Pas arrivé à temps : le moteur le demandera lui-même.
      return null;
    }
  }

  static ContentType _typeOf(String file) {
    if (file.endsWith('.m3u8')) {
      return ContentType('application', 'vnd.apple.mpegurl');
    }
    if (file.endsWith('.ts')) return ContentType('video', 'mp2t');
    return ContentType('video', 'mp4');
  }

  /// Le moteur ne lit plus cette session : le relais l'oublie.
  void close() {
    if (!_closed && _fetched.isNotEmpty) {
      debugPrint('HlsPreload: $_served fichier(s) servis de mémoire sur '
          '${_fetched.length} pris en avance');
    }
    _closed = true;
    _cache.clear();
    _sessions.remove(_key);
  }
}
