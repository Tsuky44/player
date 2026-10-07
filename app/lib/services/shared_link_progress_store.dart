import 'package:shared_preferences/shared_preferences.dart';

import '../models/shared_show.dart';

/// Ce que l'appareil retient de la lecture d'un lien de partage : le serveur
/// ne garde la progression de personne sans compte (ADR-0037 §5, §8).
///
/// Une position par média, et pour une saison ou une série les épisodes vus
/// et le dernier regardé — de quoi proposer « Reprendre » comme à un compte.
class SharedLinkProgressStore {
  SharedLinkProgressStore(this.code);

  /// Le code du lien suffit comme clé : 128 bits d'aléa, il ne se répète pas
  /// d'un serveur à l'autre.
  final String code;

  String _positionKey(int? episodeId) => episodeId == null
      ? 'onyx-share-position:$code'
      : 'onyx-share-position:$code:$episodeId';
  String get _finishedKey => 'onyx-share-finished:$code';
  String get _lastKey => 'onyx-share-last:$code';

  /// Où l'appareil s'était arrêté, en secondes : dans le média du lien, ou
  /// dans l'épisode [episodeId] d'une saison ou d'une série.
  Future<int> position({int? episodeId}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_positionKey(episodeId)) ?? 0;
  }

  /// Note où en est la lecture. Un média fini perd sa position : le relancer
  /// le reprend du début.
  Future<void> record({
    int? episodeId,
    required int positionSeconds,
    required bool finished,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (finished) {
      await prefs.remove(_positionKey(episodeId));
    } else {
      await prefs.setInt(_positionKey(episodeId), positionSeconds);
    }
    if (episodeId == null) return;
    await prefs.setInt(_lastKey, episodeId);
    final id = '$episodeId';
    final seen = prefs.getStringList(_finishedKey) ?? const <String>[];
    // Un épisode vu qu'on relance redevient « en cours ».
    if (finished != seen.contains(id)) {
      await prefs.setStringList(
        _finishedKey,
        finished ? [...seen, id] : [for (final e in seen) if (e != id) e],
      );
    }
  }

  /// L'avancement dans les épisodes [episodeIds] d'une saison ou d'une série.
  Future<SharedLinkProgress> snapshot(Iterable<int> episodeIds) async {
    final prefs = await SharedPreferences.getInstance();
    final positions = <int, int>{};
    for (final id in episodeIds) {
      final position = prefs.getInt(_positionKey(id)) ?? 0;
      if (position > 0) positions[id] = position;
    }
    return SharedLinkProgress(
      positions: positions,
      finished: {
        for (final raw in prefs.getStringList(_finishedKey) ?? const <String>[])
          if (int.tryParse(raw) case final id?) id,
      },
      lastEpisodeId: prefs.getInt(_lastKey),
    );
  }
}
