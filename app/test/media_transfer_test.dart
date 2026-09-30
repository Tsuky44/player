import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/downloads/background_media_transfer_io.dart';
import 'package:onyx/services/downloads/media_transfer_io.dart';
import 'package:onyx_background_downloads/onyx_background_downloads.dart';

import 'test_doubles.dart';

/// Le fichier du serveur : 1 000 octets, chacun reconnaissable par sa position.
final Uint8List _source =
    Uint8List.fromList(List.generate(1000, (i) => i % 251));

/// Un `/stream` qui honore `Range:` comme le serveur d'Onyx.
ResponseBody _serve(RequestOptions r, {bool honourRange = true}) {
  final range = r.headers['Range'] as String?;
  if (range == null || !honourRange) {
    return ResponseBody.fromBytes(_source, 200, headers: {
      'content-length': ['${_source.length}'],
    });
  }
  final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
  final start = int.parse(match[1]!);
  if (start >= _source.length) return ResponseBody.fromBytes(const [], 416);
  final end = match[2]!.isEmpty ? _source.length - 1 : int.parse(match[2]!);
  return ResponseBody.fromBytes(_source.sublist(start, end + 1), 206, headers: {
    'content-range': ['bytes $start-$end/${_source.length}'],
    'content-length': ['${end - start + 1}'],
  });
}

Dio _dio(ResponseBody Function(RequestOptions) handle) =>
    Dio()..httpClientAdapter = Adapter(handle);

/// La session d'arrière-plan d'iOS, jouée par le test : une tranche confiée
/// arrive sur le disque au tour suivant, sauf si le serveur la refuse.
class _FakeSession implements BackgroundDownloadSession {
  final Map<String, List<int>> _pending = {};
  final Map<String, String> _failures = {};
  final List<int> enqueued = [];
  final List<String> cancelled = [];

  /// Débuts de tranches que le serveur refuse (ticket révoqué, par exemple).
  Set<int> refuse = {};

  @override
  Future<void> enqueue({
    required String url,
    required int start,
    required int end,
    required String destination,
  }) async {
    enqueued.add(start);
    _pending[destination] = [start, end];
  }

  @override
  Future<BackgroundDownloadSnapshot> snapshot(String prefix) async {
    final running = <String, int>{};
    for (final entry in _pending.entries.toList()) {
      final [start, end] = entry.value;
      _pending.remove(entry.key);
      if (refuse.contains(start)) {
        _failures[entry.key] = 'HTTP 401';
        continue;
      }
      if (!File(entry.key).parent.existsSync()) continue;
      File(entry.key).writeAsBytesSync(_source.sublist(start, end + 1));
    }
    return BackgroundDownloadSnapshot(running: running, failures: _failures);
  }

  @override
  Future<void> cancel(String prefix) async => cancelled.add(prefix);
}

void main() {
  late Directory dir;
  late File target;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('onyx_transfer_test');
    target = File('${dir.path}${Platform.pathSeparator}video.mkv');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Laissé au système (Windows garde parfois la main un instant).
    }
  });

  Future<TransferOutcome> fetch(
    MediaTransfer transfer, {
    TransferCancellation? cancellation,
    List<(int, int)>? progress,
  }) =>
      transfer.fetch(
        url: 'http://nas:8080/stream?media_id=1',
        target: target,
        cancellation: cancellation ?? TransferCancellation(),
        onProgress: (received, total) => progress?.add((received, total)),
      );

  group('DioMediaTransfer', () {
    test('reprend un fichier partiel à l’octet où il s’était arrêté',
        () async {
      target.writeAsBytesSync(_source.sublist(0, 300));
      final ranges = <String?>[];
      final progress = <(int, int)>[];
      final outcome = await fetch(
        DioMediaTransfer(_dio((r) {
          ranges.add(r.headers['Range'] as String?);
          return _serve(r);
        })),
        progress: progress,
      );
      expect(outcome, isA<TransferCompleted>());
      expect(ranges, ['bytes=300-']);
      expect(target.readAsBytesSync(), _source);
      expect(progress.first, (300, 1000));
      expect(progress.last, (1000, 1000));
    });

    test('un serveur qui ignore le Range fait repartir de zéro', () async {
      target.writeAsBytesSync(utf8.encode('début périmé'));
      final outcome = await fetch(
          DioMediaTransfer(_dio((r) => _serve(r, honourRange: false))));
      expect(outcome, isA<TransferCompleted>());
      expect(target.readAsBytesSync(), _source);
    });

    test('416 veut dire « tout est déjà là »', () async {
      target.writeAsBytesSync(_source);
      final outcome = await fetch(DioMediaTransfer(_dio(_serve)));
      expect(outcome, isA<TransferCompleted>());
      expect(target.lengthSync(), 1000);
    });

    test('un refus du serveur est un échec affiché, pas une exception',
        () async {
      final outcome = await fetch(DioMediaTransfer(
          _dio((r) => ResponseBody.fromString('ticket expiré', 401))));
      expect(outcome, isA<TransferFailed>());
      expect((outcome as TransferFailed).message, 'HTTP 401');
    });
  });

  group('BackgroundMediaTransfer', () {
    BackgroundMediaTransfer transfer(_FakeSession session,
            {ResponseBody Function(RequestOptions)? serve}) =>
        BackgroundMediaTransfer(
          dio: _dio(serve ?? _serve),
          session: session,
          chunkBytes: 400,
          pollEvery: const Duration(milliseconds: 1),
        );

    test('confie toutes les tranches d’un coup et assemble le fichier',
        () async {
      final session = _FakeSession();
      final progress = <(int, int)>[];
      final outcome = await fetch(transfer(session), progress: progress);
      expect(outcome, isA<TransferCompleted>());
      // Toutes au premier tour : une tâche créée app au premier plan part
      // tout de suite, écran verrouillé ou non.
      expect(session.enqueued, [0, 400, 800]);
      expect(target.readAsBytesSync(), _source);
      expect(progress.every((p) => p.$2 == 1000), isTrue);
      expect(
        dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
        ['video.mkv'],
        reason: 'les tranches assemblées sont effacées',
      );
    });

    test('ce qui est arrivé app suspendue n’est pas redemandé', () async {
      // Deux tranches déposées par le système pendant que l'app dormait, et un
      // fichier déjà assemblé jusqu'à 400.
      target.writeAsBytesSync(_source.sublist(0, 400));
      File('${target.path}.part-800')
          .writeAsBytesSync(_source.sublist(800, 1000));
      final session = _FakeSession();
      final outcome = await fetch(transfer(session));
      expect(outcome, isA<TransferCompleted>());
      expect(session.enqueued, [400]);
      expect(target.readAsBytesSync(), _source);
    });

    test('un assemblage interrompu reprend à l’octet manquant', () async {
      // L'app a été tuée au milieu de l'ajout de la tranche 400 : le fichier
      // en a déjà 100 octets, la tranche est encore là en entier.
      target.writeAsBytesSync(_source.sublist(0, 500));
      File('${target.path}.part-400')
          .writeAsBytesSync(_source.sublist(400, 800));
      File('${target.path}.part-0').writeAsBytesSync(_source.sublist(0, 400));
      final have = await assembleChunks(target);
      expect(have, 800);
      expect(target.readAsBytesSync(), _source.sublist(0, 800));
      expect(File('${target.path}.part-0').existsSync(), isFalse);
      expect(File('${target.path}.part-400').existsSync(), isFalse);
    });

    test('une tranche toujours refusée fait échouer le média avec sa raison',
        () async {
      final session = _FakeSession()..refuse = {400};
      final outcome = await fetch(transfer(session));
      expect(outcome, isA<TransferFailed>());
      expect((outcome as TransferFailed).message, 'HTTP 401');
      expect(session.enqueued.where((s) => s == 400).length, 3);
      expect(session.cancelled, isNotEmpty);
      // Ce qui est arrivé reste : la reprise ne le redemandera pas.
      expect(target.lengthSync(), 400);
    });

    test('une pause annule les tranches en cours et garde le reste', () async {
      final session = _FakeSession();
      final cancellation = TransferCancellation()..cancel();
      final outcome =
          await fetch(transfer(session), cancellation: cancellation);
      expect(outcome, isA<TransferCancelled>());
      expect(session.enqueued, isEmpty);
    });

    test('un serveur qui ignore le Range passe par le transfert d’un bloc',
        () async {
      final session = _FakeSession();
      final outcome = await fetch(
          transfer(session, serve: (r) => _serve(r, honourRange: false)));
      expect(outcome, isA<TransferCompleted>());
      expect(session.enqueued, isEmpty);
      expect(target.readAsBytesSync(), _source);
    });
  });
}
