@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/hls_playlist.dart';
import 'package:onyx/services/hls_preload.dart';

const _master = '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=NO,URI="stream_2.m3u8?ticket=T"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Français",DEFAULT=YES,URI="stream_1.m3u8?ticket=T"
#EXT-X-STREAM-INF:BANDWIDTH=3660000,RESOLUTION=1280x720,AUDIO="audio"
stream_0.m3u8?ticket=T
''';

String _playlist(String stem, int segments) => [
      '#EXTM3U',
      '#EXT-X-START:TIME-OFFSET=0,PRECISE=YES',
      '#EXT-X-TARGETDURATION:2',
      for (var i = 0; i < segments; i++) ...[
        '#EXTINF:2.000000,',
        '${stem}_00$i.ts?ticket=T',
      ],
      '',
    ].join('\n');

/// Un serveur Onyx réduit à une session HLS : il note ce qu'on lui demande.
class _Upstream {
  late final HttpServer server;
  final asked = <String>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final file = request.uri.pathSegments.last;
      asked.add('$file?${request.uri.query}');
      final response = request.response;
      if (request.uri.queryParameters['ticket'] != 'T') {
        response.statusCode = HttpStatus.unauthorized;
      } else if (file == 'master.m3u8') {
        response.write(_master);
      } else if (file == 'stream_0.m3u8') {
        response.write(_playlist('stream_0', 5));
      } else if (file == 'stream_1.m3u8') {
        response.write(_playlist('stream_1', 5));
      } else if (file.endsWith('.ts')) {
        response.add(utf8.encode('octets de $file'));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  }

  String get masterUrl =>
      'http://127.0.0.1:${server.port}/api/v1/stream/7/s/master.m3u8?ticket=T';
}

Future<({int status, String body})> _get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decodeStream(response),
    );
  } finally {
    client.close(force: true);
  }
}

/// Le début d'une session préparée, pris d'avance pour que le changement de
/// source ne fige pas l'image. Voir ADR-0056.
void main() {
  test('la playlist maîtresse donne la vidéo et le son par défaut', () {
    final master = parseHlsMaster(_master);
    expect(master.video, 'stream_0.m3u8?ticket=T');
    expect(master.audio, 'stream_1.m3u8?ticket=T');

    expect(parseHlsMaster('#EXTM3U\n').video, isNull);
  });

  test('une playlist dit ses segments, leur durée et son initialisation', () {
    final ts = parseHlsMediaPlaylist(_playlist('stream_0', 3));
    expect(ts.initUri, isNull);
    expect(ts.segments.map((s) => s.uri),
        ['stream_0_000.ts?ticket=T', 'stream_0_001.ts?ticket=T', 'stream_0_002.ts?ticket=T']);
    expect(ts.segments.first.duration, 2.0);

    final fmp4 = parseHlsMediaPlaylist(
        '#EXTM3U\n#EXT-X-MAP:URI="init_0.mp4?ticket=T"\n#EXTINF:1.96,\nstream_0_000.m4s?ticket=T\n');
    expect(fmp4.initUri, 'init_0.mp4?ticket=T');
    expect(fmp4.segments.single.duration, 1.96);
  });

  group('le relais local', () {
    late _Upstream upstream;
    HlsPreload? preload;

    setUp(() async {
      upstream = _Upstream();
      await upstream.start();
      preload = await HlsPreload.open(upstream.masterUrl);
    });

    tearDown(() async {
      preload?.close();
      await upstream.server.close(force: true);
    });

    test('télécharge d’avance ce qu’on lui demande, sans que le serveur '
        'tienne la session pour lue', () async {
      final relay = preload;
      // Hors Windows et Linux, il n'y a pas de relais : le moteur ouvre la
      // session lui-même.
      if (relay == null) return;
      await relay.warm(seconds: 4, budget: const Duration(seconds: 5));

      expect(relay.readySeconds, 4);
      final segments = upstream.asked.where((a) => a.contains('.ts')).toList();
      expect(segments, [
        'stream_1_000.ts?ticket=T&warm=1',
        'stream_1_001.ts?ticket=T&warm=1',
        'stream_0_000.ts?ticket=T&warm=1',
        'stream_0_001.ts?ticket=T&warm=1',
      ]);
    });

    test('sert de mémoire ce qui est arrivé, et demande le reste au serveur',
        () async {
      final relay = preload;
      if (relay == null) return;
      await relay.warm(seconds: 2, budget: const Duration(seconds: 5));
      upstream.asked.clear();
      final base = relay.masterUrl.substring(
          0, relay.masterUrl.lastIndexOf('/') + 1);

      final master = await _get(relay.masterUrl);
      expect(master.status, 200);
      expect(master.body, contains('stream_0.m3u8?ticket=T'));

      final cached = await _get('${base}stream_0_000.ts?ticket=T');
      expect(cached.body, 'octets de stream_0_000.ts');
      expect(upstream.asked, isEmpty,
          reason: 'ni la playlist maîtresse ni le segment pris d’avance ne '
              'retournent au serveur');

      // La playlist grandit avec la session : toujours celle du serveur.
      final playlist = await _get('${base}stream_0.m3u8?ticket=T');
      expect(playlist.body, contains('stream_0_004.ts'));
      // Un segment qui n'a pas été pris d'avance, ou déjà servi une fois.
      final later = await _get('${base}stream_0_003.ts?ticket=T');
      final again = await _get('${base}stream_0_000.ts?ticket=T');
      expect(later.body, 'octets de stream_0_003.ts');
      expect(again.body, 'octets de stream_0_000.ts');
      expect(upstream.asked, [
        'stream_0.m3u8?ticket=T',
        'stream_0_003.ts?ticket=T',
        'stream_0_000.ts?ticket=T',
      ], reason: 'sans `warm` : cette fois le moteur lit la session');
    });

    test('rend au moteur le refus du serveur tel quel', () async {
      final relay = preload;
      if (relay == null) return;
      final base = relay.masterUrl.substring(
          0, relay.masterUrl.lastIndexOf('/') + 1);

      expect((await _get('${base}stream_0_000.ts?ticket=autre')).status, 401);
      expect((await _get('${base}absent.bin?ticket=T')).status, 404);
    });

    test('une session fermée, ou inconnue, ne répond plus', () async {
      final relay = preload;
      if (relay == null) return;
      final url = relay.masterUrl;
      final other = url.replaceFirst(RegExp(r'/[0-9a-f]{32}/'), '/${'0' * 32}/');

      expect((await _get(other)).status, 404);
      relay.close();
      expect((await _get(url)).status, 404);
    });
  });
}
