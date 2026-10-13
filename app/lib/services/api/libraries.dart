part of '../api_client.dart';

/// Les bibliothèques du serveur et le catalogue de chacune (ADR-0058).
///
/// Un morceau d'[ApiClient], sorti du fichier pour qu'il reste lisible : les
/// méthodes sont des méthodes d'instance comme avant, et les doublures de test
/// qui étendent [ApiClient] peuvent toujours les surcharger.
mixin _LibraryEndpoints {
  Dio get _dio;
  String get baseUrl;
  String? get accountId;
  ConditionalGetCache get _libraryLists;

  /// Les serveurs qui ont annoncé leurs bibliothèques sur `/api/ping` : la
  /// question ne se repose pas à chaque rechargement. Un « non » n'est pas
  /// retenu — le serveur peut être mis à jour pendant que l'app est ouverte.
  final Set<String> _serversListingLibraries = {};

  Future<bool> _serverListsLibraries() async {
    final server = baseUrl;
    if (_serversListingLibraries.contains(server)) return true;
    final ping = await _dio.get('/api/ping');
    final info = ServerCapabilities.tryParse(ping.data);
    if (info == null || !info.supports(ServerCapabilities.libraries)) {
      return false;
    }
    _serversListingLibraries.add(server);
    return true;
  }

  /// Les bibliothèques du serveur, dans l'ordre où elles ont été créées.
  ///
  /// Un serveur plus ancien n'en liste pas : il n'a que ses films et ses
  /// séries, rendus ici comme [MediaLibrary.legacy].
  Future<List<MediaLibrary>> getLibraries() async {
    if (!await _serverListsLibraries()) return MediaLibrary.legacy;
    final response = await _dio.get('/api/libraries');
    return (response.data as List<dynamic>)
        .map((e) => MediaLibrary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<MediaLibrary> createLibrary({
    required String name,
    required LibraryKind kind,
    required String path,
  }) async {
    final response = await _dio.post('/api/libraries', data: {
      'name': name,
      'kind': kind.wire,
      'path': path,
    });
    return MediaLibrary.fromJson(response.data as Map<String, dynamic>);
  }

  /// Renomme une bibliothèque ou change son dossier. Son type ne se change
  /// pas : on la supprime et on la recrée.
  Future<MediaLibrary> updateLibrary(
    int id, {
    required String name,
    required String path,
  }) async {
    final response = await _dio.put('/api/libraries/$id', data: {
      'name': name,
      'path': path,
    });
    return MediaLibrary.fromJson(response.data as Map<String, dynamic>);
  }

  /// Retire une bibliothèque et son catalogue. Les fichiers restent sur le
  /// disque du serveur.
  Future<void> deleteLibrary(int id) async {
    await _dio.delete('/api/libraries/$id');
  }

  /// Les films d'une bibliothèque, avec la progression du compte.
  Future<List<HomeMediaItem>> getLibraryMovies(MediaLibrary library) async {
    final data = await _libraryLists.get(_dio, _listPath('/api/movies', library),
        scope: accountId ?? '');
    return (data as List<dynamic>)
        .map((e) => HomeMediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Les séries d'une bibliothèque.
  Future<List<Media>> getLibraryShows(MediaLibrary library) async {
    final data = await _libraryLists.get(_dio, _listPath('/api/shows', library),
        scope: accountId ?? '');
    return (data as List<dynamic>)
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String _listPath(String route, MediaLibrary library) =>
      library.isLegacy ? route : '$route?library=${library.id}';
}
