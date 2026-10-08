import 'dart:async';

import 'package:dio/dio.dart';

/// `ApiClient.getProgressRevision` du serveur courant : sans [since], le jeton
/// tout de suite ; avec, la réponse attend que le jeton s'en écarte.
typedef ProgressRevisionFetch = Future<String> Function(
  String? since,
  CancelToken cancelToken,
);

/// Suit la progression du compte en direct : garde une requête ouverte sur le
/// jeton de révision du serveur et prévient quand il a bougé — une série qui
/// avance sur un autre appareil, un épisode coché vu ailleurs.
///
/// C'est le jeton qui est attendu, pas les données : l'écran ne relit
/// l'accueil ou sa fiche que lorsqu'il y a quelque chose de neuf à y lire.
class ProgressRevisionWatch {
  ProgressRevisionWatch({
    required this.fetch,
    required this.onChanged,
    this.baselineTimeout = const Duration(seconds: 2),
    this.idlePause = const Duration(seconds: 1),
    this.retryDelay = const Duration(seconds: 5),
    this.changePause = const Duration(seconds: 15),
    this.heldAtLeast = const Duration(seconds: 2),
  });

  final ProgressRevisionFetch fetch;
  final void Function() onChanged;

  /// Au-delà, le rafraîchissement demandé par [start] part sans attendre le
  /// jeton : hors ligne, la connexion met dix secondes à échouer, et l'écran
  /// n'a pas à rester figé d'ici là.
  final Duration baselineTimeout;

  /// Souffle entre deux attentes que le serveur a tenues puis rendues sans
  /// changement, une vingtaine de secondes chacune.
  final Duration idlePause;

  /// Attente après un échec (hors ligne), ou après une réponse à vide rendue
  /// sans avoir été tenue : un serveur d'avant le long-poll ignore `since` et
  /// répond tout de suite, et serait sinon sondé à chaque [idlePause].
  final Duration retryDelay;

  /// Souffle après un changement annoncé. Un lecteur ouvert ailleurs écrit sa
  /// position toutes les cinq secondes, et chaque écriture bouge le jeton :
  /// sans ce délai, l'accueil d'un téléphone posé à côté de la télé se relisait
  /// en entier à ce rythme pendant tout le film. Le premier changement est
  /// toujours annoncé à l'instant ; ceux qui tombent pendant le souffle sont
  /// réunis en un seul avis à sa fin, puisque l'attente repart du jeton lu.
  final Duration changePause;

  /// En dessous, une réponse à vide n'a pas été tenue par le serveur.
  final Duration heldAtLeast;

  int _generation = 0;
  CancelToken? _request;
  Timer? _pauseTimer;
  Timer? _holdTimer;
  Completer<void>? _pause;

  /// Lit le jeton courant, puis attend ses changements jusqu'à [stop].
  ///
  /// [refresh] prévient une fois d'office, pour l'écran qui revient à la vue.
  /// L'avis part **après** la lecture du jeton : la dernière position d'un
  /// lecteur qu'on vient de quitter peut arriver au serveur une fraction de
  /// seconde plus tard, et relire avant d'avoir un point de départ la
  /// laisserait passer sans que rien ne la signale ensuite.
  void start({bool refresh = false}) {
    stop();
    unawaited(_run(_generation, refresh));
  }

  void stop() {
    _generation++;
    _request?.cancel();
    _request = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _holdTimer?.cancel();
    _holdTimer = null;
    final pause = _pause;
    _pause = null;
    if (pause != null && !pause.isCompleted) pause.complete();
  }

  Future<void> _run(int generation, bool refresh) async {
    var last = await _ask(null, timeout: baselineTimeout);
    if (generation != _generation) return;
    if (refresh) onChanged();

    while (generation == _generation) {
      var held = false;
      _holdTimer = Timer(heldAtLeast, () => held = true);
      final next = await _ask(last);
      if (generation != _generation) return;
      _holdTimer?.cancel();
      if (next == null) {
        await _wait(retryDelay);
        continue;
      }
      final previous = last;
      last = next;
      if (previous != null && previous != next) {
        onChanged();
        await _wait(changePause);
      } else {
        await _wait(previous != null && !held ? retryDelay : idlePause);
      }
    }
  }

  /// Null sur un échec : l'écran garde ce qu'il montre.
  Future<String?> _ask(String? since, {Duration? timeout}) async {
    final request = _request = CancelToken();
    try {
      final answer = fetch(since, request);
      return await (timeout == null ? answer : answer.timeout(timeout));
    } catch (_) {
      if (!request.isCancelled) request.cancel();
      return null;
    }
  }

  Future<void> _wait(Duration duration) {
    final pause = _pause = Completer<void>();
    _pauseTimer = Timer(duration, () {
      if (!pause.isCompleted) pause.complete();
    });
    return pause.future;
  }
}
