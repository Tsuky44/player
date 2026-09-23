import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/playback/live_subtitles.dart';
import 'package:onyx/services/hls_session.dart';

/// Les sous-titres qu'une session HLS écrit pendant qu'on la regarde
/// (ADR-0031) : le fichier grandit, le client n'en relit que la suite, et ne
/// montre jamais une réplique à moitié arrivée.

/// Un serveur qui sert un WebVTT en train de s'écrire, comme `serveLiveSubtitle`.
class _GrowingFile {
  List<int> bytes = [];
  final List<int> requestedFrom = [];
  int? forcedStatus;

  void append(String text) => bytes = [...bytes, ...utf8.encode(text)];

  Future<LiveSubtitleChunk> fetch(String url, int from) async {
    requestedFrom.add(from);
    if (forcedStatus != null) return (status: forcedStatus!, bytes: <int>[]);
    if (bytes.isEmpty) return (status: 204, bytes: <int>[]);
    if (from == 0) return (status: 200, bytes: bytes);
    if (from >= bytes.length) return (status: 416, bytes: <int>[]);
    return (status: 206, bytes: bytes.sublist(from));
  }
}

void main() {
  late _GrowingFile file;
  late LiveSubtitleFeed feed;
  late StreamController<Duration> positions;

  setUp(() {
    file = _GrowingFile();
    // Le rythme régulier est coupé : chaque test relève à la main.
    feed = LiveSubtitleFeed(
      fetch: file.fetch,
      pollInterval: const Duration(hours: 1),
    );
    positions = StreamController<Duration>.broadcast();
  });

  tearDown(() async {
    feed.dispose();
    await positions.close();
  });

  Future<void> at(Duration position) async {
    positions.add(position);
    await Future<void>.delayed(Duration.zero);
  }

  test('une réplique à moitié écrite attend la suite', () async {
    file.append('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nBonj');
    feed.follow('sub_0.vtt', positions: positions.stream);
    await feed.pollNow();
    await at(const Duration(milliseconds: 1500));
    expect(feed.lines.value, isEmpty);

    file.append('our\n\n');
    await feed.pollNow();
    await at(const Duration(milliseconds: 1500));
    expect(feed.lines.value, ['Bonjour']);
  });

  test('seule la suite du fichier est redemandée', () async {
    file.append('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nUn\n\n');
    feed.follow('sub_0.vtt', positions: positions.stream);
    await feed.pollNow();
    final firstLength = file.bytes.length;

    file.append('00:00:05.000 --> 00:00:06.000\nDeux\n\n');
    await feed.pollNow();
    await feed.pollNow(); // rien de neuf : 416

    expect(file.requestedFrom, [0, firstLength, file.bytes.length]);
    await at(const Duration(milliseconds: 5500));
    expect(feed.lines.value, ['Deux']);
  });

  test('un caractère coupé entre deux relevés reste entier', () async {
    final all = utf8.encode('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nÉté\n\n');
    // Coupe au milieu du « É », qui tient sur deux octets.
    final split = all.indexOf(0xC3) + 1;
    file.bytes = all.sublist(0, split);
    feed.follow('sub_0.vtt', positions: positions.stream);
    await feed.pollNow();
    file.bytes = all;
    await feed.pollNow();
    await at(const Duration(milliseconds: 1500));
    expect(feed.lines.value, ['Été']);
  });

  test('pas encore de réplique : rien, et on continue de relever', () async {
    feed.follow('sub_0.vtt', positions: positions.stream);
    await feed.pollNow();
    expect(feed.lines.value, isEmpty);
    file.append('WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nEnfin\n\n');
    await feed.pollNow();
    await at(const Duration(milliseconds: 500));
    expect(feed.lines.value, ['Enfin']);
  });

  test('changer de piste efface la précédente', () async {
    file.append('WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nAncienne\n\n');
    feed.follow('sub_0.vtt', positions: positions.stream);
    await feed.pollNow();
    await at(const Duration(seconds: 2));
    expect(feed.lines.value, ['Ancienne']);

    feed.stop();
    expect(feed.lines.value, isEmpty);
    expect(feed.url, isNull);
  });

  test('completeBlocksEnd coupe après la dernière ligne vide', () {
    List<int> b(String s) => utf8.encode(s);
    expect(completeBlocksEnd(b('WEBVTT')), 0);
    expect(completeBlocksEnd(b('WEBVTT\n\nabc')), 8);
    expect(completeBlocksEnd(b('WEBVTT\r\n\r\nabc')), 10);
  });

  test('une piste écrite par la session est prête, une image non', () {
    final tracks = MediaTracks(audio: const [], subtitles: [
      MediaSubtitleTrack(lang: 'fr', name: 'Français', typedIndex: 0),
      MediaSubtitleTrack(lang: 'img1', name: 'PGS', typedIndex: 1, image: true),
      MediaSubtitleTrack(lang: 'en', name: 'English', typedIndex: 2),
    ]);
    const sources = [LiveSubtitleSource(typedIndex: 0, url: 'sub_0.vtt')];

    final marked = withLiveSubtitles(tracks, sources);
    expect(marked.subtitles.map((s) => s.ready), [true, false, false]);
    expect(liveSourceFor(sources, marked.subtitles[0])?.url, 'sub_0.vtt');
    expect(liveSourceFor(sources, marked.subtitles[1]), isNull);
    expect(liveSourceFor(sources, marked.subtitles[2]), isNull);
  });

  test('un serveur plus ancien ne dit rien : on retombe sur l\'extraction', () {
    final old = HlsSession.fromJson({'session_id': 's', 'master_url': 'm'});
    expect(old.subtitles, isNull);

    final none = HlsSession.fromJson(
        {'session_id': 's', 'master_url': 'm', 'subtitles': <dynamic>[]});
    expect(none.subtitles, isEmpty);

    final live = HlsSession.fromJson({
      'session_id': 's',
      'master_url': 'm',
      'subtitles': [
        {'typed_index': 2, 'url': 'http://h/sub_2.vtt?ticket=t'},
      ],
    });
    expect(live.subtitles!.single.typedIndex, 2);
  });
}
