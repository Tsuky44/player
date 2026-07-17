import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/media_request.dart';
import '../services/api_client.dart';

class MediaRequestsProvider extends ChangeNotifier {
  final ApiClient apiClient;

  MediaRequestsProvider(this.apiClient);

  List<RequestMediaItem> _items = const [];
  String _type = 'all';
  String _query = '';
  int _page = 0;
  int _totalPages = 1;
  int _loadGeneration = 0;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;

  List<RequestMediaItem> get items => _items;
  String get type => _type;
  String get query => _query;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _page < _totalPages;
  String? get errorMessage => _errorMessage;

  Future<void> load({String? type, String? query}) async {
    _type = type ?? _type;
    _query = query?.trim() ?? _query;
    _page = 0;
    _totalPages = 1;
    _items = const [];
    _errorMessage = null;
    _isLoading = true;
    final generation = ++_loadGeneration;
    notifyListeners();

    try {
      final result = await apiClient.getRequestCatalog(
          page: 1, type: _type, query: _query);
      if (generation != _loadGeneration) return;
      _items = result.results;
      _page = result.page;
      _totalPages = result.totalPages;
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
      final result = await apiClient.getRequestCatalog(
          page: _page + 1, type: _type, query: _query);
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
    } catch (error) {
      if (generation == _loadGeneration) _errorMessage = _messageFor(error);
    } finally {
      if (generation == _loadGeneration) {
        _isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<RequestMediaDetails> loadDetails(RequestMediaItem item) {
    return apiClient.getRequestMediaDetails(item.id, item.mediaType);
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
        return 'TMDB n''est pas configuré. Vérifiez TMDB_API_KEY.';
      }
    }
    return 'Impossible de charger les médias.';
  }
}