import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/models.dart';
import '../../../models/series_track_preferences.dart';
import '../../../services/api_client.dart';

/// La langue audio et le sous-titre choisis pour une série, retenus au-delà
/// de la séance de lecture (ADR-0044).
///
/// Le compte tient la référence : le choix fait sur le téléphone vaut sur le
/// téléviseur, et le lendemain. L'appareil en garde une copie, qui sert quand
/// le serveur tarde ou manque, et qui note ce qui n'a pas encore pu partir.
class SeriesTrackMemory {
  SeriesTrackMemory._(this._api, this._episodeId, this._cacheKey);

  /// Null pour tout ce qui n'est pas un épisode : un film n'a pas de suite à
  /// qui transmettre son réglage.
  static SeriesTrackMemory? forMedia(ApiClient api, Media media) {
    if (media.type != MediaType.episode) return null;
    // La copie locale se range par saison, faute de connaître la série sans
    // le serveur : elle n'est qu'un repli, la série entière vit sur le compte.
    final scope =
        media.parentId != null ? 's${media.parentId}' : 'e${media.id}';
    final account = api.accountId ?? api.baseUrl;
    return SeriesTrackMemory._(api, media.id, 'series_tracks|$account|$scope');
  }

  /// Ce qu'on laisse au serveur pour répondre avant d'ouvrir avec la copie
  /// locale. La demande part en même temps que le ticket de lecture : elle ne
  /// coûte rien tant qu'elle ne dépasse pas ce délai.
  static const _serverWait = Duration(milliseconds: 700);

  static const _audioField = 'audio_lang';
  static const _subtitleField = 'subtitle';

  final ApiClient _api;
  final int _episodeId;
  final String _cacheKey;

  /// Avance à chaque choix : une réponse du serveur partie avant lui ne doit
  /// pas le recouvrir dans la copie locale.
  int _generation = 0;

  /// Les écritures se suivent, pour que deux choix rapprochés ne se croisent
  /// pas entre la copie locale et le serveur.
  Future<void> _queue = Future<void>.value();

  @visibleForTesting
  Future<void> get settled => _queue;

  /// Le choix retenu pour la série, ou null s'il n'y en a pas.
  ///
  /// [cacheFirst] pour un épisode téléchargé : il doit s'ouvrir sans attendre
  /// un serveur peut-être absent, qui met alors la copie à jour pour la suite.
  Future<SeriesTrackPreferences?> load({bool cacheFirst = false}) async {
    final cached = await _readCache();
    final refresh = _refresh(cached);
    if (cacheFirst) {
      unawaited(refresh.then<void>((_) {}, onError: _logFailure));
      return _orNull(cached?.prefs);
    }
    try {
      return _orNull(await refresh.timeout(_serverWait));
    } catch (e) {
      _logFailure(e);
      return _orNull(cached?.prefs);
    }
  }

  void rememberAudio(String lang) =>
      _remember(_audioField, (prefs) => prefs.withAudioLang(lang));

  void rememberSubtitle(SeriesSubtitleChoice choice) =>
      _remember(_subtitleField, (prefs) => prefs.withSubtitle(choice));

  /// Ce qui a été choisi ici sans atteindre le serveur part d'abord : c'est
  /// l'appareil qui porte alors la valeur récente, pas le compte.
  Future<SeriesTrackPreferences> _refresh(_CachedChoice? cached) async {
    final generation = _generation;
    final pending = cached?.pending ?? const <String>{};
    final remote = pending.isEmpty
        ? await _api.getSeriesTrackPreferences(_episodeId)
        : await _api.updateSeriesTrackPreferences(
            _episodeId, _payload(cached!.prefs, pending));
    if (generation == _generation) {
      await _writeCache(_CachedChoice(remote, const {}));
    }
    return remote;
  }

  void _remember(
    String field,
    SeriesTrackPreferences Function(SeriesTrackPreferences) change,
  ) {
    final generation = ++_generation;
    _queue = _queue.then((_) async {
      try {
        final cached = await _readCache();
        final prefs = change(cached?.prefs ?? const SeriesTrackPreferences());
        final pending = {...?cached?.pending, field};
        // Noté avant l'envoi : si le serveur est injoignable, ou si l'app se
        // ferme entre les deux, la prochaine lecture saura quoi renvoyer.
        await _writeCache(_CachedChoice(prefs, pending));
        final remote = await _api.updateSeriesTrackPreferences(
            _episodeId, _payload(prefs, pending));
        if (generation == _generation) {
          await _writeCache(_CachedChoice(remote, const {}));
        }
      } catch (e) {
        _logFailure(e);
      }
    });
  }

  static Map<String, Object> _payload(
    SeriesTrackPreferences prefs,
    Set<String> fields,
  ) {
    final subtitle = prefs.subtitle;
    return {
      if (fields.contains(_audioField)) _audioField: prefs.audioLang ?? '',
      if (fields.contains(_subtitleField) && subtitle != null)
        _subtitleField: subtitle.toJson(),
    };
  }

  static SeriesTrackPreferences? _orNull(SeriesTrackPreferences? prefs) =>
      prefs == null || prefs.isEmpty ? null : prefs;

  static void _logFailure(Object e) =>
      debugPrint('SeriesTrackMemory: serveur indisponible — $e');

  Future<_CachedChoice?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return _CachedChoice(
        SeriesTrackPreferences.fromJson(
            Map<String, dynamic>.from(json['prefs'] as Map)),
        (json['pending'] as List? ?? const []).whereType<String>().toSet(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(_CachedChoice choice) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'prefs': choice.prefs.toJson(),
          'pending': choice.pending.toList(),
        }),
      );
    } catch (_) {
      // Une copie qui n'a pas pu s'écrire ne retire rien à cette séance.
    }
  }
}

class _CachedChoice {
  const _CachedChoice(this.prefs, this.pending);

  final SeriesTrackPreferences prefs;

  /// Les champs changés ici et pas encore reçus par le serveur.
  final Set<String> pending;
}
