import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import '../../l10n/tr.dart';

/// Comment les octets d'un média arrivent sur le disque.
///
/// Le magasin hors ligne décide *quoi* rapatrier et *quand* ; un transfert ne
/// sait que remplir un fichier, en reprenant là où il s'arrête. Deux
/// implémentations : [DioMediaTransfer], un `GET Range:` écrit en append dans le
/// processus de l'app (ADR-0010 §1), et, sur iPhone, une session d'arrière-plan
/// du système qui continue écran verrouillé (ADR-0040).
abstract interface class MediaTransfer {
  /// Remplit [target] depuis [url], en reprenant à la taille actuelle du
  /// fichier. [onProgress] reçoit les octets présents et la taille finale
  /// (0 tant qu'elle est inconnue).
  ///
  /// Une panne attendue (réseau, statut HTTP) revient en [TransferFailed] ;
  /// seule une erreur imprévue est levée.
  Future<TransferOutcome> fetch({
    required String url,
    required File target,
    required TransferCancellation cancellation,
    required void Function(int received, int total) onProgress,
  });
}

sealed class TransferOutcome {
  const TransferOutcome();
}

/// [target] contient le fichier entier.
final class TransferCompleted extends TransferOutcome {
  const TransferCompleted();
}

/// Arrêté par [TransferCancellation.cancel] : pause, suppression, changement
/// de serveur. Ce qui est arrivé reste sur le disque.
final class TransferCancelled extends TransferOutcome {
  const TransferCancelled();
}

/// Le réseau ou le serveur a lâché. [message] s'affiche sur la ligne du média.
final class TransferFailed extends TransferOutcome {
  const TransferFailed(this.message);
  final String message;
}

/// Le signal d'arrêt d'un transfert, posé par le magasin hors ligne.
class TransferCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  /// Un [CancelToken] de Dio qui suit ce signal.
  CancelToken toCancelToken() {
    final token = CancelToken();
    unawaited(_cancelled.future.then((_) => token.cancel('cancelled')));
    return token;
  }

  /// Attend [duration], ou moins si le transfert est arrêté entre-temps.
  Future<void> pause(Duration duration) =>
      Future.any([Future<void>.delayed(duration), _cancelled.future]);
}

/// Le message d'une panne de transfert, pour la ligne du média.
String describeTransferError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.connectionError:
      return tr('Serveur injoignable');
    case DioExceptionType.receiveTimeout:
      return tr('Transfert interrompu');
    default:
      return e.message ?? tr('Téléchargement impossible');
  }
}

/// Taille finale du fichier, déduite de l'en-tête qui la porte.
///
/// En réponse partielle c'est `Content-Range: bytes a-b/total` qui la donne ;
/// `Content-Length` ne décrit alors que le morceau restant, d'où l'addition
/// avec ce qui est déjà sur le disque.
int totalBytesOf(Headers headers, {required int alreadyHave}) {
  final range = headers.value('content-range');
  if (range != null) {
    final slash = range.lastIndexOf('/');
    if (slash > 0) {
      final parsed = int.tryParse(range.substring(slash + 1).trim());
      if (parsed != null && parsed > 0) return parsed;
    }
  }
  final length = int.tryParse(headers.value('content-length') ?? '');
  if (length != null && length > 0) return length + alreadyHave;
  return 0;
}

/// Le transfert dans le processus de l'app : un GET `Range:` écrit en append.
///
/// Une app tuée en plein téléchargement laisse un fichier partiel parfaitement
/// utilisable, qui repart à l'octet où il s'était arrêté. Un serveur qui
/// ignorerait le `Range` (réponse 200 au lieu de 206) fait repartir de zéro
/// plutôt que de produire un fichier corrompu.
class DioMediaTransfer implements MediaTransfer {
  DioMediaTransfer(this._dio);

  final Dio _dio;

  @override
  Future<TransferOutcome> fetch({
    required String url,
    required File target,
    required TransferCancellation cancellation,
    required void Function(int received, int total) onProgress,
  }) async {
    if (cancellation.isCancelled) return const TransferCancelled();
    var received = await target.exists() ? await target.length() : 0;
    IOSink? sink;
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancellation.toCancelToken(),
        options: Options(
          responseType: ResponseType.stream,
          headers: received > 0 ? {'Range': 'bytes=$received-'} : null,
          // 416 signifie « tu as déjà tout » — une réponse à traiter, pas une
          // exception à propager.
          validateStatus: (code) => code != null && code < 500,
        ),
      );

      final status = response.statusCode ?? 0;
      if (status == 416) return const TransferCompleted();
      if (status != 200 && status != 206) return TransferFailed('HTTP $status');
      if (received > 0 && status == 200) {
        // Le serveur a ignoré le Range et renvoie le fichier entier : repartir
        // de zéro est la seule façon de ne pas concaténer deux débuts.
        received = 0;
      }

      final total = totalBytesOf(response.headers, alreadyHave: received);
      onProgress(received, total);

      final out = target.openWrite(
        mode: received > 0 ? FileMode.append : FileMode.write,
      );
      sink = out;
      await for (final chunk in response.data!.stream) {
        out.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await out.flush();
      await out.close();
      sink = null;
      return const TransferCompleted();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return const TransferCancelled();
      return TransferFailed(describeTransferError(e));
    } finally {
      await sink?.close();
    }
  }
}
