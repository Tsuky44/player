import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'tv_link.dart';

/// Native implementation of the television's link listener — see
/// `tv_link_host.dart`.
///
/// The listener is deliberately tiny and deliberately short-lived: it exists
/// only while the sign-in screen is on, it accepts exactly one delivery, and it
/// closes the moment that delivery lands. What protects it is the one-time code
/// in the QR, which is only knowable by someone who can see the television —
/// the same guarantee the pairing code had, and the reason a stranger on the
/// same network cannot point this screen at a server of their choosing.
class TvLinkHost implements TvLinkSession {
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isLinux ||
          Platform.isMacOS || Platform.isWindows);

  HttpServer? _server;
  String? _code;
  final Completer<TvLinkPayload> _completer = Completer<TvLinkPayload>();

  @override
  Future<TvLinkPayload> get linked => _completer.future;

  /// Opens the listener and returns what the QR should carry, or null when
  /// there is no usable address — a television with no network has nothing to
  /// offer, and the screen says so rather than showing an unreachable code.
  @override
  Future<TvLinkOffer?> start({required String deviceName}) async {
    await stop();

    final host = await _localAddress();
    if (host == null) return null;

    final code = _generateCode();
    HttpServer server;
    try {
      // Port 0: the OS picks a free one. A fixed port would collide with
      // whatever else a set-top box is running, and the number travels in the
      // QR anyway so nothing needs to guess it.
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    } catch (error) {
      debugPrint('TvLinkHost: cannot bind ($error)');
      return null;
    }

    _server = server;
    _code = code;
    server.listen(_handle, onError: (Object error) {
      debugPrint('TvLinkHost: listener error ($error)');
    });

    final name = Uri.encodeQueryComponent(deviceName);
    return TvLinkOffer(
      url: 'http://$host:${server.port}/link?c=$code&n=$name',
      host: host,
      port: server.port,
    );
  }

  @override
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _code = null;
    if (server == null) return;
    try {
      await server.close(force: true);
    } catch (_) {
      // Closing a listener that already failed is not worth reporting.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    TvLinkPayload? delivered;
    try {
      if (request.method == 'POST' && request.uri.path == '/link') {
        delivered = await _handleDelivery(request);
      } else {
        // Anything else is a person who scanned the code with their phone's
        // camera instead of the app. The camera opens a browser, and a browser
        // has no session to give — so the page says where to go rather than
        // failing with a blank error.
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_instructionsPage);
      }
    } catch (error) {
      debugPrint('TvLinkHost: request failed ($error)');
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        // The response may already be committed; nothing left to say.
      }
    } finally {
      try {
        await response.close();
      } catch (_) {
        // Client hung up.
      }
    }

    // Only once the answer is on the wire. Completing earlier would tear the
    // listener down — `stop` closes connections by force — and the phone would
    // read a dropped socket as a failure on a link that actually worked.
    if (delivered == null || _completer.isCompleted) return;
    _completer.complete(delivered);
    // The offer is spent: one delivery, and no socket left open on a
    // living-room network for as long as the app happens to run.
    unawaited(stop());
  }

  /// Reads one delivery and answers it. Returns the payload on success, so the
  /// caller can hand it over *after* the response has been flushed.
  Future<TvLinkPayload?> _handleDelivery(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;

    if (_completer.isCompleted) {
      // One delivery only. A second one is either a retry that already
      // succeeded, or something that has no business here.
      response.statusCode = HttpStatus.conflict;
      response.write('{"error":"already linked"}');
      return null;
    }

    Map<String, dynamic> body;
    try {
      final raw = await utf8.decoder.bind(request).join();
      body = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
      response.write('{"error":"invalid body"}');
      return null;
    }

    final expected = _code;
    final code = body['code'];
    if (expected == null || code is! String || !_codesMatch(expected, code)) {
      response.statusCode = HttpStatus.forbidden;
      response.write('{"error":"invalid code"}');
      return null;
    }

    final serverUrl = (body['server'] as String?)?.trim();
    final token = (body['token'] as String?)?.trim();
    final rawUser = body['user'];
    if (serverUrl == null ||
        serverUrl.isEmpty ||
        token == null ||
        token.isEmpty ||
        rawUser is! Map<String, dynamic>) {
      response.statusCode = HttpStatus.badRequest;
      response.write('{"error":"missing server, token or user"}');
      return null;
    }

    User user;
    try {
      user = User.fromJson(rawUser);
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
      response.write('{"error":"invalid user"}');
      return null;
    }

    response.statusCode = HttpStatus.ok;
    response.write('{"status":"ok"}');

    return TvLinkPayload(serverUrl: serverUrl, token: token, user: user);
  }

  /// Constant-time-ish comparison. The code is short-lived and single-use, so
  /// this is belt and braces — but a timing oracle on a value an attacker can
  /// probe at will is not worth leaving in.
  static bool _codesMatch(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// 32 hex characters from the secure generator. Never read aloud and never
  /// typed — it only ever travels inside the QR — so it is sized for guessing
  /// resistance rather than for legibility.
  static String _generateCode() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// This device's address on the local network.
  ///
  /// A link-local address means DHCP failed, and nothing can reach it — the
  /// offer would be a QR pointing nowhere, so it is treated as "no network".
  static Future<String?> _localAddress() async {
    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
    } catch (error) {
      debugPrint('TvLinkHost: cannot list interfaces ($error)');
      return null;
    }

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.address.startsWith('169.254.')) continue;
        return address.address;
      }
    }
    return null;
  }

  static const String _instructionsPage = '''
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Onyx — Connecter ce téléviseur</title>
<style>
  body { margin:0; background:#0b0b0d; color:#f4f4f5; font-family:system-ui,sans-serif;
         display:flex; min-height:100vh; align-items:center; justify-content:center; }
  main { max-width:22rem; padding:2rem; text-align:center; line-height:1.55; }
  h1 { font-size:1.25rem; margin:0 0 1rem; }
  p { margin:0 0 .75rem; color:#a1a1aa; }
  strong { color:#f4f4f5; }
</style>
</head>
<body>
<main>
  <h1>Presque&nbsp;!</h1>
  <p>Ce code doit être scanné depuis l'application Onyx, pas depuis l'appareil photo.</p>
  <p>Ouvrez <strong>Onyx</strong> sur votre téléphone, puis
     <strong>Compte → Connecter un téléviseur</strong>, et scannez à nouveau.</p>
</main>
</body>
</html>
''';
}
