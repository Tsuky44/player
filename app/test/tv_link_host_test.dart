@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/tv_link_host.dart';

/// Posts a delivery to the television, the way the phone does, and returns
/// its status code.
///
/// The body is read before the client is closed: closing it by force first
/// cuts the connection under a response that is still arriving, which failed
/// these tests intermittently with "Connection closed while receiving data".
Future<int> deliver(
  Uri endpoint,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Map<String, dynamic> validBody(String code) => {
      'code': code,
      'server': 'http://192.168.1.50:8080',
      'token': 'session-token',
      'user': {'id': 7, 'username': 'mathis'},
    };

void main() {
  late TvLinkHost host;

  setUp(() => host = TvLinkHost());
  tearDown(() => host.stop());

  test('the offer points at this device and carries a one-time code', () async {
    final offer = await host.start(deviceName: 'Salon');
    // A machine with no non-loopback IPv4 has nothing to offer, and the screen
    // is meant to say so rather than show an unreachable code.
    if (offer == null) return;

    final uri = Uri.parse(offer.url);
    expect(uri.scheme, 'http');
    expect(uri.path, '/link');
    expect(uri.host, offer.host);
    expect(uri.port, offer.port);
    expect(uri.queryParameters['c'], isNotEmpty);
    expect(uri.queryParameters['n'], 'Salon');
  });

  test('a delivery carrying the code hands over the server and the session',
      () async {
    final offer = await host.start(deviceName: 'Salon');
    if (offer == null) return;
    final code = Uri.parse(offer.url).queryParameters['c']!;

    final status = await deliver(
      Uri.parse('http://127.0.0.1:${offer.port}/link'),
      validBody(code),
    );
    expect(status, 200);

    final payload = await host.linked;
    expect(payload.serverUrl, 'http://192.168.1.50:8080');
    expect(payload.token, 'session-token');
    expect(payload.user.username, 'mathis');
  });

  test('a delivery with the wrong code is refused', () async {
    final offer = await host.start(deviceName: 'Salon');
    if (offer == null) return;

    final status = await deliver(
      Uri.parse('http://127.0.0.1:${offer.port}/link'),
      validBody('not-the-code'),
    );
    // The code is the only thing standing between this listener and anyone else
    // on the network: it decides which server the television is pointed at.
    expect(status, 403);
  });

  test('a delivery missing the server or the token is refused', () async {
    final offer = await host.start(deviceName: 'Salon');
    if (offer == null) return;
    final code = Uri.parse(offer.url).queryParameters['c']!;

    final status = await deliver(
      Uri.parse('http://127.0.0.1:${offer.port}/link'),
      {'code': code, 'token': 'session-token'},
    );
    expect(status, 400);
  });

  test('the listener closes itself once it has been used', () async {
    final offer = await host.start(deviceName: 'Salon');
    if (offer == null) return;
    final code = Uri.parse(offer.url).queryParameters['c']!;

    final endpoint = Uri.parse('http://127.0.0.1:${offer.port}/link');
    await deliver(endpoint, validBody(code));
    await host.linked;

    // One delivery only, and no socket left open on a living-room network.
    await expectLater(
      deliver(endpoint, validBody(code)),
      throwsA(isA<SocketException>()),
    );
  });

  test('a browser that scanned the code is told where to go', () async {
    final offer = await host.start(deviceName: 'Salon');
    if (offer == null) return;

    final client = HttpClient();
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:${offer.port}/link'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close(force: true);

    expect(response.statusCode, 200);
    // The camera app opens a browser, and a browser has no session to give.
    // A blank error there is a dead end; this is the one instruction that
    // unsticks it.
    expect(body, contains('Connecter un téléviseur'));
  });
}
