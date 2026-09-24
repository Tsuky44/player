import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../utils/app_platform.dart';
import 'dns_warmup_io.dart';

/// Un relais `CONNECT` sur la boucle locale, pour que mpv n'attende jamais le
/// DNS du système.
///
/// La libmpv de l'app ouvre ses flux avec libcurl, qui résout le nom au moment
/// d'ouvrir — sur le chemin de la première image — et sous Windows cette
/// résolution peut coûter 11 s (voir [DnsWarmup]). mpv n'a pas d'option pour
/// fixer l'adresse d'un nom, et forcer une adresse IP dans l'URL casse le TLS :
/// ni libcurl ni FFmpeg n'envoient alors le nom que Cloudflare attend (essayé :
/// `verifyhost` n'y change rien).
///
/// Derrière un proxy, en revanche, libcurl ne résout rien : il demande
/// `CONNECT hôte:443`, puis mène le TLS lui-même, de bout en bout, avec le bon
/// nom. Ce relais n'a qu'à ouvrir la connexion vers la dernière adresse connue
/// de l'hôte ([DnsWarmup.addressesFor]) et recopier les octets, chiffrés, dans
/// les deux sens. Mesuré sur la libmpv de l'app : 117 ms jusqu'au premier
/// démultiplexeur, contre 11,3 s en résolvant.
///
/// Rien n'est déchiffré ni lu au-delà de la ligne `CONNECT`. Il n'écoute que
/// sur 127.0.0.1 : un programme local qui s'en servirait n'obtiendrait rien
/// qu'il ne puisse déjà faire lui-même.
abstract final class StreamProxy {
  static Future<ServerSocket?>? _server;

  /// La valeur de `http-proxy` pour ouvrir [url] : le relais pour un flux
  /// HTTPS sur desktop, une chaîne vide sinon (pas de proxy).
  ///
  /// HTTPS seulement : en HTTP, libcurl enverrait au proxy des requêtes
  /// entières à relayer plutôt qu'un tunnel, et les serveurs joints en HTTP
  /// sont ceux du réseau local, adressés par IP ou par un nom local. Desktop
  /// seulement : c'est là que le DNS lent a été constaté, et un relais local
  /// sur iOS devrait survivre aux suspensions de l'app.
  static Future<String> routeFor(String url) async {
    if (!AppPlatform.isDesktop) return '';
    if (Uri.tryParse(url)?.scheme != 'https') return '';
    final server = await (_server ??= _start());
    return server == null ? '' : 'http://127.0.0.1:${server.port}';
  }

  static Future<ServerSocket?> _start() async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) => unawaited(serve(client)));
      return server;
    } catch (e) {
      // Sans relais, mpv résout lui-même : plus lent, jamais cassé.
      debugPrint('StreamProxy: relais indisponible ($e) — résolution directe');
      return null;
    }
  }

  /// Sert un client : lit la ligne `CONNECT`, ouvre le tunnel, recopie.
  @visibleForTesting
  static Future<void> serve(
    Socket client, {
    Future<Socket> Function(String host, int port)? connect,
  }) async {
    final header = BytesBuilder(copy: false);
    final rest = StreamController<Uint8List>();
    var tunnelled = false;
    final headerRead = Completer<({String host, int port})?>();

    late final StreamSubscription<Uint8List> fromClient;
    fromClient = client.listen(
      (chunk) {
        if (tunnelled) {
          rest.add(chunk);
          return;
        }
        header.add(chunk);
        final bytes = header.toBytes();
        final end = _headerEnd(bytes);
        if (end < 0) {
          if (bytes.length > _maxHeader && !headerRead.isCompleted) {
            headerRead.complete(null);
          }
          return;
        }
        tunnelled = true;
        if (end < bytes.length) rest.add(Uint8List.sublistView(bytes, end));
        if (!headerRead.isCompleted) {
          headerRead
              .complete(parseConnect(latin1.decode(bytes.sublist(0, end))));
        }
      },
      onError: (_) {
        if (!headerRead.isCompleted) headerRead.complete(null);
        rest.close();
      },
      onDone: () {
        if (!headerRead.isCompleted) headerRead.complete(null);
        rest.close();
      },
      cancelOnError: true,
    );

    final target = await headerRead.future;
    if (target == null) {
      await fromClient.cancel();
      client.add(latin1.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
      await client.close().catchError((_) => client);
      return;
    }

    final Socket upstream;
    try {
      upstream = await (connect ?? _connect)(target.host, target.port);
    } catch (e) {
      debugPrint('StreamProxy: ${target.host}:${target.port} injoignable: $e');
      await fromClient.cancel();
      client.add(latin1.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
      await client.close().catchError((_) => client);
      return;
    }

    client.add(latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'));
    // Vers le serveur : la poignée de main TLS et les requêtes, peu de chose.
    unawaited(upstream
        .addStream(rest.stream)
        .then((_) => upstream.close())
        .catchError((_) => upstream.destroy()));
    // Vers mpv : le film. `addStream` suspend la lecture du serveur tant que
    // mpv n'a pas repris ce qu'on lui a donné — la mémoire reste bornée.
    try {
      await client.addStream(upstream);
      await client.close();
    } catch (_) {
      client.destroy();
    } finally {
      upstream.destroy();
      await fromClient.cancel();
    }
  }

  static const _maxHeader = 8 * 1024;

  /// La position juste après `\r\n\r\n`, ou -1.
  static int _headerEnd(Uint8List bytes) {
    for (var i = 3; i < bytes.length; i++) {
      if (bytes[i] == 10 &&
          bytes[i - 1] == 13 &&
          bytes[i - 2] == 10 &&
          bytes[i - 3] == 13) {
        return i + 1;
      }
    }
    return -1;
  }

  /// `CONNECT hôte:port HTTP/1.1` → l'hôte et le port ; null pour toute autre
  /// requête. Les crochets d'une adresse IPv6 sont retirés.
  @visibleForTesting
  static ({String host, int port})? parseConnect(String header) {
    final line = header.split('\r\n').first.split(' ');
    if (line.length != 3 || line[0] != 'CONNECT') return null;
    final target = line[1];
    final colon = target.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(target.substring(colon + 1));
    var host = target.substring(0, colon);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (port == null || port <= 0 || port > 65535 || host.isEmpty) return null;
    return (host: host, port: port);
  }

  /// Les adresses connues d'abord, le nom en dernier recours : une adresse
  /// périmée qui ne répond plus coûte trois secondes, pas une lecture.
  static Future<Socket> _connect(String host, int port) async {
    for (final address in DnsWarmup.addressesFor(host) ?? const []) {
      try {
        return await Socket.connect(address, port,
            timeout: const Duration(seconds: 3));
      } catch (_) {}
    }
    return Socket.connect(host, port, timeout: const Duration(seconds: 30));
  }
}
