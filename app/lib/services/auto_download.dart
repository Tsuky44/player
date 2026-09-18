import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../models/offline_download.dart';
import 'api_client.dart';
import 'download_manager.dart';
import 'download_preferences.dart';
import 'playback_access.dart';

/// Ce que le réapprovisionnement a besoin de demander au serveur.
///
/// Une interface plutôt qu'un [ApiClient] directement, parce que la règle —
/// « combien d'avance reste-t-il, et lesquels descendre ensuite » — se teste
/// sans HTTP, et qu'elle est la seule chose intéressante ici.
abstract class AutoDownloadCatalog {
  /// L'épisode qui suit celui-ci, saison suivante comprise. Null quand la série
  /// s'arrête là, ou quand le serveur n'a pas la suite.
  Future<HomeMediaItem?> nextEpisodeAfter(int episodeId);

  /// Tous les épisodes que le serveur possède pour cette série.
  Future<List<HomeMediaItem>> allEpisodesOf(int showId);
}

/// Ce que le réapprovisionnement a besoin de savoir de l'appareil.
abstract class AutoDownloadLibrary {
  /// Les séries dont au moins un épisode est là.
  Set<int> get showIds;

  /// Ce qui est sur l'appareil pour cette série, dans l'ordre de lecture.
  List<OfflineDownload> entriesForShow(int showId);

  Future<int> enqueue(
    List<HomeMediaItem> episodes, {
    required int showId,
    String? showTitle,
    String? showPosterUrl,
  });
}

/// Ce que l'app rapatrie sans qu'on le lui demande.
///
/// ## La règle
///
/// Une série dont un épisode a été téléchargé est une série qu'on est en train
/// de regarder. À partir de là, l'app garde [DownloadPreferences.keepAhead]
/// épisodes non vus d'avance sur l'appareil : chaque épisode terminé en libère
/// une place, et la place se remplit toute seule avec le suivant. La réserve ne
/// bouge donc jamais de taille — c'est tout l'intérêt, on ne se demande plus
/// jamais si on a de quoi tenir le trajet.
///
/// En mode [AutoDownloadMode.wholeShow] la question ne se pose même plus : tout
/// ce que le serveur a de cette série descend, sauf ce qui a déjà été vu.
///
/// ## Ce que ça ne fait pas
///
/// Rien ne part sur un réseau facturé sans accord (voir [DownloadPreferences]) :
/// la file se remplit quand même, et attend. C'est volontaire — ce qui a été
/// prévu pendant le trajet du matin descend en arrivant, sans que personne ait
/// eu à y penser.
///
/// Rien ne s'efface non plus : la réserve se remplit, elle ne se vide pas. La
/// suppression reste un geste (ADR-0010 §9), et « supprimer les vus » est là
/// pour la fournée.
class AutoDownloadPlanner {
  AutoDownloadPlanner({
    required this.catalog,
    required this.library,
    required this.preferences,
  });

  final AutoDownloadCatalog catalog;
  final AutoDownloadLibrary library;
  final DownloadPreferences preferences;

  /// Combien d'épisodes non vus sont là, ou en route, pour cette série.
  ///
  /// Un épisode en cours de transfert compte : il sera là avant qu'on en ait
  /// besoin, et le compter deux fois ferait descendre la saison entière.
  /// Un épisode en échec ou mis en pause à la main ne compte pas — il n'arrive
  /// nulle part tout seul.
  static int reserveOf(List<OfflineDownload> entries) => entries
      .where((e) => !e.isFinished && (e.isCompleted || e.isActive))
      .length;

  /// Remet la série à niveau. Renvoie le nombre d'épisodes mis en file.
  Future<int> topUp(int showId) async {
    if (preferences.mode == AutoDownloadMode.off) return 0;

    final entries = library.entriesForShow(showId);
    // Personne n'a rien demandé pour cette série : ce n'est pas à nous de
    // commencer. Le premier épisode reste un geste.
    if (entries.isEmpty) return 0;

    final known = {for (final entry in entries) entry.mediaId};
    final picks = preferences.mode == AutoDownloadMode.wholeShow
        ? await _wholeShow(showId, known)
        : await _keepAhead(entries, known);
    if (picks.isEmpty) return 0;

    final anchor = entries.first;
    return library.enqueue(
      picks,
      showId: showId,
      showTitle: anchor.showTitle,
      showPosterUrl: anchor.showPosterUrl,
    );
  }

  Future<List<HomeMediaItem>> _wholeShow(int showId, Set<int> known) async {
    final all = await catalog.allEpisodesOf(showId);
    return [
      for (final episode in all)
        // Déjà vu : le rapatrier occuperait le disque pour un épisode qu'on ne
        // rouvrira pas, et « supprimer les vus » l'effacerait dans la foulée.
        if (!known.contains(episode.media.id) &&
            episode.isAvailable &&
            !episode.isFinished)
          episode,
    ];
  }

  Future<List<HomeMediaItem>> _keepAhead(
    List<OfflineDownload> entries,
    Set<int> known,
  ) async {
    final missing = preferences.keepAhead - reserveOf(entries);
    if (missing <= 0) return const [];

    // On repart du dernier épisode connu de la série, pas du dernier regardé :
    // ce qui est déjà sur l'appareil ne se retéléchargera pas, et la réserve se
    // construit devant, pas au milieu.
    var cursor = entries.last.mediaId;
    final picks = <HomeMediaItem>[];
    final visited = <int>{cursor};

    while (picks.length < missing) {
      final next = await catalog.nextEpisodeAfter(cursor);
      if (next == null) break; // fin de la série, ou le serveur n'a pas la suite
      final id = next.media.id;
      // Un serveur qui renverrait l'épisode courant comme suivant ferait tourner
      // la boucle sans fin. On s'arrête, plutôt que d'y croire.
      if (!visited.add(id)) break;
      cursor = id;
      if (known.contains(id)) continue; // déjà sur l'appareil : on enjambe
      if (!next.isAvailable || next.isFinished) continue;
      picks.add(next);
    }
    return picks;
  }
}

/// Le déclencheur : qui regarde quoi, et à quel moment le plan se rejoue.
///
/// Tout passe par les notifications du magasin hors ligne, parce que tout ce qui
/// compte s'y voit — un épisode terminé, un transfert fini, une suppression. Une
/// signature par série évite de redemander au serveur ce qu'on vient de lui
/// demander : pendant un transfert le magasin notifie plusieurs fois par
/// seconde, et aucune de ces notifications ne change le plan.
class AutoDownloadService {
  AutoDownloadService({
    required DownloadManager manager,
    required ApiClient api,
    required DownloadPreferences preferences,
    required bool Function() isOnline,
    AutoDownloadCatalog? catalog,
  })  : _manager = manager,
        _preferences = preferences,
        _isOnline = isOnline {
    _planner = AutoDownloadPlanner(
      catalog: catalog ?? ApiAutoDownloadCatalog(api),
      library: _ManagerLibrary(manager),
      preferences: preferences,
    );
  }

  final DownloadManager _manager;
  final DownloadPreferences _preferences;
  final bool Function() _isOnline;
  late final AutoDownloadPlanner _planner;

  /// Le temps qu'il faut pour qu'une salve de notifications retombe. Un
  /// transfert qui démarre en produit plusieurs d'affilée.
  static const Duration _settle = Duration(seconds: 2);

  Timer? _timer;
  bool _running = false;
  bool _again = false;
  final Map<int, String> _signatures = {};
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _manager.addListener(_schedule);
    _preferences.addListener(_onPreferencesChanged);
    _schedule();
  }

  /// Le réseau ou le serveur est revenu : ce qui n'avait pas pu être planifié
  /// hors ligne se planifie maintenant.
  void refresh() {
    _signatures.clear();
    _schedule();
  }

  void _onPreferencesChanged() {
    // Changer de mode ou de taille de réserve invalide tous les plans, y
    // compris ceux qui avaient conclu « rien à faire ».
    _signatures.clear();
    _schedule();
  }

  void _schedule() {
    if (!_manager.isSupported || !_preferences.isAutoEnabled) return;
    _timer?.cancel();
    _timer = Timer(_settle, () => unawaited(_run()));
  }

  Future<void> _run() async {
    if (!_preferences.isAutoEnabled || !_manager.isSupported) return;
    // Sans serveur il n'y a pas de « prochain épisode » à demander. Le retour du
    // serveur rejoue le plan (voir [refresh]).
    if (!_isOnline()) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      for (final showId in _manager.downloadedShowIds) {
        final entries = _manager.entriesForShow(showId);
        final signature = _signatureOf(entries);
        if (_signatures[showId] == signature) continue;
        // Posée **avant** le plan : une série dont le plan n'ajoute rien ne doit
        // pas être redemandée au serveur à chaque notification suivante.
        _signatures[showId] = signature;
        try {
          await _planner.topUp(showId);
        } catch (e) {
          // Le serveur n'a pas répondu : on réessaiera au prochain changement,
          // et la signature est effacée pour que ce prochain changement compte.
          _signatures.remove(showId);
          debugPrint(
              'Téléchargements: réserve de la série $showId impossible: '
              '${redactPlaybackDiagnostic(e)}');
        }
      }
    } finally {
      _running = false;
      if (_again) {
        _again = false;
        _schedule();
      }
    }
  }

  /// Ce qui, dans l'état d'une série, peut changer le plan. Les octets reçus
  /// n'en font délibérément pas partie.
  String _signatureOf(List<OfflineDownload> entries) {
    final reserve = AutoDownloadPlanner.reserveOf(entries);
    final anchor = entries.isEmpty ? 0 : entries.last.mediaId;
    return '${_preferences.mode.name}/${_preferences.keepAhead}/'
        '${entries.length}/$reserve/$anchor';
  }

  void dispose() {
    _timer?.cancel();
    if (!_started) return;
    _manager.removeListener(_schedule);
    _preferences.removeListener(_onPreferencesChanged);
  }
}

/// Le catalogue vu par le serveur.
class ApiAutoDownloadCatalog implements AutoDownloadCatalog {
  ApiAutoDownloadCatalog(this._api);

  final ApiClient _api;

  @override
  Future<HomeMediaItem?> nextEpisodeAfter(int episodeId) async {
    final response = await _api.getNextEpisode(episodeId);
    if (!response.hasNext) return null;
    return response.episode;
  }

  @override
  Future<List<HomeMediaItem>> allEpisodesOf(int showId) async {
    final seasons = await _api.getShowSeasons(showId);
    final episodes = <HomeMediaItem>[];
    for (final season in seasons) {
      // Une saison que le serveur n'a pas est une saison qu'on ne peut pas
      // télécharger : la demander à MediaHub reste un geste de l'utilisateur.
      if (!season.isAvailable || season.id <= 0) continue;
      episodes.addAll(await _api.getSeasonEpisodes(season.id));
    }
    episodes.sort((a, b) {
      final season = (a.media.effectiveSeasonNumber ?? 0)
          .compareTo(b.media.effectiveSeasonNumber ?? 0);
      if (season != 0) return season;
      return (a.media.effectiveEpisodeNumber ?? 0)
          .compareTo(b.media.effectiveEpisodeNumber ?? 0);
    });
    return episodes;
  }
}

class _ManagerLibrary implements AutoDownloadLibrary {
  _ManagerLibrary(this._manager);

  final DownloadManager _manager;

  @override
  Set<int> get showIds => _manager.downloadedShowIds;

  @override
  List<OfflineDownload> entriesForShow(int showId) =>
      _manager.entriesForShow(showId);

  @override
  Future<int> enqueue(
    List<HomeMediaItem> episodes, {
    required int showId,
    String? showTitle,
    String? showPosterUrl,
  }) =>
      _manager.downloadAll(
        episodes,
        showId: showId,
        showTitle: showTitle,
        showPosterUrl: showPosterUrl,
        automatic: true,
      );
}
