import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/media_request.dart';
import '../models/request_catalog_filters.dart';
import '../services/api_client.dart';
import '../l10n/tr.dart';

class MediaRequestsProvider extends ChangeNotifier {
  final ApiClient apiClient;

  MediaRequestsProvider(this.apiClient);

  List<RequestMediaItem> _items = const [];
  String _type = 'all';
  String _query = '';
  RequestCatalogFilters _filters = RequestCatalogFilters.defaults;
  int _page = 0;
  int _totalPages = 1;
  int _loadGeneration = 0;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;

  /// Les pages suivantes, demandées dès que la précédente est là.
  ///
  /// [loadMore] attendait d'être à 900 px du bas pour demander la page, puis
  /// les affiches se téléchargeaient à l'affichage : chaque lot arrivait avec
  /// un trou de cartes vides. Deux pages d'avance, parce qu'une grille de
  /// bureau (6 à 8 colonnes) n'en fait que trois rangées.
  final Map<int, Future<RequestCatalogPage>> _ahead = {};
  static const _pagesAhead = 2;

  /// Appelé avec les cartes de chaque page préchargée : l'écran y chauffe
  /// les affiches à la taille où il les dessine.
  void Function(List<RequestMediaItem> items)? onPagePrefetched;

  List<RequestMediaItem> get items => _items;
  String get type => _type;
  String get query => _query;
  RequestCatalogFilters get filters => _filters;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _page < _totalPages;
  String? get errorMessage => _errorMessage;

  /// Vide le catalogue de demandes du serveur précédent, chargement en cours
  /// compris — d'où l'incrément de génération, qui fait retomber dans le vide
  /// la réponse partie avant la bascule. Voir [HomeProvider.reset].
  void reset() {
    _loadGeneration++;
    _ahead.clear();
    _items = const [];
    _type = 'all';
    _query = '';
    _filters = RequestCatalogFilters.defaults;
    _page = 0;
    _totalPages = 1;
    _isLoading = false;
    _isLoadingMore = false;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> load({
    String? type,
    String? query,
    RequestCatalogFilters? filters,
  }) async {
    _type = type ?? _type;
    _query = query?.trim() ?? _query;
    if (filters != null) {
      _filters = filters;
    }
    _page = 0;
    _totalPages = 1;
    _items = const [];
    _errorMessage = null;
    _isLoading = true;
    _ahead.clear();
    final generation = ++_loadGeneration;
    notifyListeners();

    try {
      final result = await _fetch(1);
      if (generation != _loadGeneration) return;
      _items = result.results;
      _page = result.page;
      _totalPages = result.totalPages;
      _prefetch(_page + 1, _totalPages);
    } catch (error) {
      if (generation != _loadGeneration) return;
      _errorMessage = _messageFor(error);
    } finally {
      if (generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !hasMore) return;
    _isLoadingMore = true;
    final generation = _loadGeneration;
    notifyListeners();

    try {
      final next = _page + 1;
      final ahead = _ahead.remove(next);
      // Une page préchargée en échec est redemandée : l'erreur ne s'affiche
      // que si ce second essai échoue aussi.
      final result = ahead == null
          ? await _fetch(next)
          : await ahead.then((page) => page,
              onError: (Object _) => _fetch(next));
      if (generation != _loadGeneration) return;
      final known =
          _items.map((item) => '${item.mediaType.name}:${item.id}').toSet();
      _items = [
        ..._items,
        ...result.results
            .where((item) => known.add('${item.mediaType.name}:${item.id}')),
      ];
      _page = result.page;
      _totalPages = result.totalPages;
      _prefetch(_page + 1, _totalPages);
    } catch (error) {
      if (generation == _loadGeneration) _errorMessage = _messageFor(error);
    } finally {
      if (generation == _loadGeneration) {
        _isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<RequestCatalogPage> _fetch(int page) => apiClient.getRequestCatalog(
        page: page,
        type: _type,
        query: _query,
        filters: _filters,
      );

  /// Précharge [page] s'il reste une place dans [_ahead], puis la suivante
  /// quand elle arrive. Une page déjà en route prolonge seulement la chaîne.
  void _prefetch(int page, int totalPages) {
    if (page > totalPages) return;
    final generation = _loadGeneration;
    final known = _ahead[page];
    if (known != null) {
      known.then((value) {
        if (generation == _loadGeneration && identical(_ahead[page], known)) {
          _prefetch(page + 1, value.totalPages);
        }
      }, onError: (Object _) {
        // loadMore redemandera cette page et affichera l'erreur s'il le faut.
      });
      return;
    }
    if (_ahead.length >= _pagesAhead) return;
    final pending = _fetch(page);
    _ahead[page] = pending;
    pending.then((value) {
      if (generation != _loadGeneration || !identical(_ahead[page], pending)) {
        return;
      }
      onPagePrefetched?.call(value.results);
      _prefetch(page + 1, value.totalPages);
    }, onError: (Object _) {
      // Rien à montrer tant qu'on n'est pas en bas : loadMore la redemandera.
    });
  }

  Future<RequestMediaDetails> loadDetails(RequestMediaItem item) {
    return apiClient.getRequestMediaDetails(item.id, item.mediaType);
  }

  Future<List<RequestEpisode>> loadSeasonEpisodes(
      int tmdbId, int seasonNumber) {
    return apiClient.getRequestSeasonEpisodes(tmdbId, seasonNumber);
  }

  Future<void> request(RequestMediaItem item, {List<int>? seasons}) async {
    await apiClient.requestMedia(item, seasons: seasons);
    _items = [
      for (final current in _items)
        if (current.id == item.id && current.mediaType == item.mediaType)
          RequestMediaItem(
            id: current.id,
            mediaType: current.mediaType,
            title: current.title,
            overview: current.overview,
            posterPath: current.posterPath,
            backdropPath: current.backdropPath,
            releaseDate: current.releaseDate,
            rating: current.rating,
            status: RequestMediaStatus.processing,
          )
        else
          current,
    ];
    notifyListeners();
  }

  String _messageFor(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map<String, dynamic> && data['error'] is String) {
        return data['error'] as String;
      }
      if (error.response?.statusCode == 503) {
        return tr('TMDB nest pas configuré. Vérifiez TMDB_API_KEY.');
      }
    }
    return tr('Impossible de charger les médias.');
  }
}
