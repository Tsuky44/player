import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:onyx_background_downloads/onyx_background_downloads.dart';
import 'package:path/path.dart' as p;

import 'chunk_plan.dart';
import 'media_transfer_io.dart';
import '../../l10n/tr.dart';

/// Le transfert de l'iPhone : les octets passent par une session URLSession
/// d'arrière-plan, qui continue écran verrouillé pendant que l'app est
/// suspendue (ADR-0040).
///
/// Le fichier est demandé en tranches de [chunkBytes], toutes confiées au
/// système d'un coup — une tâche créée app au premier plan part tout de suite,
/// alors qu'une tâche créée en arrière-plan attend le bon vouloir d'iOS. Le
/// système dépose chaque tranche finie à côté du fichier (`video.mkv.part-<début>`) ;
/// ce transfert les assemble dans l'ordre, dès qu'il tourne. Rien ne dépend donc
/// de l'app pendant qu'elle dort : au réveil, ce qui est arrivé est sur le disque.
///
/// La reprise reste celle de l'ADR-0010 : le fichier assemblé est un préfixe
/// exact du fichier d'origine, et tout repart de sa taille.
class BackgroundMediaTransfer implements MediaTransfer {
  BackgroundMediaTransfer({
    required Dio dio,
    BackgroundDownloadSession session = const BackgroundDownloadSession(),
    this.chunkBytes = 256 << 20,
    this.pollEvery = const Duration(seconds: 1),
    this.maxAttempts = 3,
  })  : _dio = dio,
        _session = session,
        _fallback = DioMediaTransfer(dio);

  final Dio _dio;
  final BackgroundDownloadSession _session;

  /// Un serveur qui ignore `Range:` ne se découpe pas : le fichier passe alors
  /// d'un bloc, dans le processus de l'app.
  final DioMediaTransfer _fallback;

  /// Assez grand pour ne pas multiplier les tâches (un remux 4K de 60 Go en
  /// fait 240), assez petit pour qu'une tranche perdue ne coûte pas cher.
  final int chunkBytes;
  final Duration pollEvery;

  /// Au-delà, une tranche qui revient sans ses octets fait échouer le média :
  /// un ticket révoqué ou un fichier disparu ne se réparent pas en insistant.
  final int maxAttempts;

  @override
  Future<TransferOutcome> fetch({
    required String url,
    required File target,
    required TransferCancellation cancellation,
    required void Function(int received, int total) onProgress,
  }) async {
    if (cancellation.isCancelled) return const TransferCancelled();

    final int? total;
    try {
      total = await _probeTotal(url, cancellation);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return const TransferCancelled();
      return TransferFailed(describeTransferError(e));
    } on _HttpStatus catch (e) {
      return TransferFailed('HTTP ${e.code}');
    }
    if (total == null) {
      return _fallback.fetch(
        url: url,
        target: target,
        cancellation: cancellation,
        onProgress: onProgress,
      );
    }

    final prefix = chunkPrefix(target);
    final attempts = <int, int>{};
    while (true) {
      if (cancellation.isCancelled) {
        await _session.cancel(prefix);
        return const TransferCancelled();
      }
      final have = await assembleChunks(target);
      if (have >= total) {
        // Une tranche redemandée pour rien peut encore courir.
        await _session.cancel(prefix);
        return const TransferCompleted();
      }

      final snapshot = await _session.snapshot(prefix);
      final running = <int>{};
      var inFlight = 0;
      snapshot.running.forEach((destination, received) {
        final start = _startOf(prefix, destination);
        if (start == null) return;
        running.add(start);
        inFlight += received;
      });
      final onDisk = await _chunksOnDisk(target);
      final plan = planChunks(
        have: have,
        total: total,
        chunkBytes: chunkBytes,
        onDisk: {for (final e in onDisk.entries) e.key: e.value.length},
        running: running,
      );
      for (final start in plan.stale) {
        await _deleteQuietly(onDisk[start]!.file);
      }
      for (final range in plan.toFetch) {
        final attempt = (attempts[range.start] ?? 0) + 1;
        if (attempt > maxAttempts) {
          await _session.cancel(prefix);
          return TransferFailed(
              snapshot.failures['$prefix${range.start}'] ??
                  tr('Transfert interrompu'));
        }
        attempts[range.start] = attempt;
        await _session.enqueue(
          url: url,
          start: range.start,
          end: range.end,
          destination: '$prefix${range.start}',
        );
      }
      onProgress(have + plan.bytesOnDisk + inFlight, total);
      await cancellation.pause(pollEvery);
    }
  }

  /// La taille du fichier, demandée par un premier octet. Null quand le
  /// serveur ignore `Range:`.
  Future<int?> _probeTotal(String url, TransferCancellation cancellation) async {
    final token = cancellation.toCancelToken();
    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        headers: const {'Range': 'bytes=0-0'},
        validateStatus: (code) => code != null && code < 500,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 200) {
      // Le fichier entier arrive : on ne le lit pas ici.
      await response.data?.stream.listen(null, onError: (_) {}).cancel();
      token.cancel('probe');
      return null;
    }
    await response.data?.stream.drain<void>();
    if (status != 206) throw _HttpStatus(status);
    final total = totalBytesOf(response.headers, alreadyHave: 0);
    return total > 0 ? total : null;
  }

  static int? _startOf(String prefix, String destination) =>
      destination.startsWith(prefix)
          ? int.tryParse(destination.substring(prefix.length))
          : null;
}

class _HttpStatus implements Exception {
  const _HttpStatus(this.code);
  final int code;
}

/// Le début de chemin commun aux tranches de [target].
String chunkPrefix(File target) => '${target.path}.part-';

class _Chunk {
  const _Chunk(this.file, this.length);
  final File file;
  final int length;
}

Future<Map<int, _Chunk>> _chunksOnDisk(File target) async {
  final chunks = <int, _Chunk>{};
  final dir = target.parent;
  if (!await dir.exists()) return chunks;
  final name = '${p.basename(target.path)}.part-';
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final base = p.basename(entity.path);
    if (!base.startsWith(name)) continue;
    final start = int.tryParse(base.substring(name.length));
    if (start == null) continue;
    chunks[start] = _Chunk(entity, await entity.length());
  }
  return chunks;
}

/// Ajoute à [target], dans l'ordre, les tranches déposées qui le prolongent,
/// et renvoie sa nouvelle taille.
///
/// Sûr d'être interrompu à tout moment : c'est la taille de [target] qui dit
/// où l'on en est. Une tranche à moitié ajoutée reprend à l'octet manquant, une
/// tranche déjà couverte est effacée sans être relue.
Future<int> assembleChunks(File target) async {
  var have = await target.exists() ? await target.length() : 0;
  while (true) {
    final chunks = await _chunksOnDisk(target);
    _Chunk? next;
    var nextStart = 0;
    for (final entry in chunks.entries) {
      final start = entry.key;
      final chunk = entry.value;
      if (start + chunk.length <= have) {
        await _deleteQuietly(chunk.file);
      } else if (start <= have) {
        next = chunk;
        nextStart = start;
      }
    }
    if (next == null) return have;
    await _append(target, next.file, skip: have - nextStart);
    await _deleteQuietly(next.file);
    have = nextStart + next.length;
  }
}

Future<void> _append(File target, File chunk, {required int skip}) async {
  final out = await target.open(mode: FileMode.append);
  final input = await chunk.open();
  try {
    await input.setPosition(skip);
    while (true) {
      final Uint8List block = await input.read(8 << 20);
      if (block.isEmpty) break;
      await out.writeFrom(block);
    }
    await out.flush();
  } finally {
    await input.close();
    await out.close();
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Déjà parti, ou repris au prochain tour.
  }
}
