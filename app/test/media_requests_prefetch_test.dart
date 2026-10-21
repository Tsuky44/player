import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/models/request_catalog_filters.dart';
import 'package:onyx/providers/media_requests_provider.dart';
import 'package:onyx/services/api_client.dart';

/// Un catalogue de [totalPages] pages de 20 cartes, qui note les pages
/// demandées et peut échouer une fois sur une page donnée.
class _CatalogServer extends ApiClient {
  _CatalogServer({this.totalPages = 6, this.failOnceOn});

  final int totalPages;
  int? failOnceOn;
  final List<int> asked = [];

  @override
  Future<RequestCatalogPage> getRequestCatalog({
    required int page,
    required String type,
    String? query,
    RequestCatalogFilters filters = RequestCatalogFilters.defaults,
  }) async {
    asked.add(page);
    if (failOnceOn == page) {
      failOnceOn = null;
      throw Exception('TMDB ne répond pas');
    }
    return RequestCatalogPage(
      page: page,
      totalPages: totalPages,
      results: [
        for (var i = 0; i < 20; i++)
          RequestMediaItem(
            id: page * 100 + i,
            mediaType: RequestMediaType.movie,
            title: 'Film ${page * 100 + i}',
            overview: '',
            posterPath: '/p${page * 100 + i}.jpg',
            backdropPath: null,
            releaseDate: '2021-01-01',
            rating: 7,
            status: RequestMediaStatus.unknown,
          ),
      ],
    );
  }
}

void main() {
  test('les deux pages suivantes partent dès que la première est là', () async {
    final server = _CatalogServer();
    final provider = MediaRequestsProvider(server);
    final warmed = <int>[];
    provider.onPagePrefetched = (items) => warmed.add(items.first.id ~/ 100);

    await provider.load();
    await pumpEventQueue();

    expect(server.asked, [1, 2, 3]);
    expect(warmed, [2, 3], reason: 'les affiches de chaque page préchargée');
    expect(provider.items, hasLength(20));
  });

  test('arriver en bas sert la page préchargée sans la redemander', () async {
    final server = _CatalogServer();
    final provider = MediaRequestsProvider(server);
    await provider.load();
    await pumpEventQueue();

    await provider.loadMore();
    await pumpEventQueue();

    expect(provider.items, hasLength(40));
    // La page 2 n'est demandée qu'une fois ; la 4 part pour garder deux pages d'avance.
    expect(server.asked, [1, 2, 3, 4]);
  });

  test('une page préchargée en échec est redemandée en arrivant en bas',
      () async {
    final server = _CatalogServer(failOnceOn: 2);
    final provider = MediaRequestsProvider(server);
    await provider.load();
    await pumpEventQueue();

    await provider.loadMore();

    expect(provider.errorMessage, isNull);
    expect(provider.items, hasLength(40));
    expect(server.asked.where((page) => page == 2), hasLength(2));
  });

  test('rien n’est préchargé au-delà de la dernière page', () async {
    final server = _CatalogServer(totalPages: 2);
    final provider = MediaRequestsProvider(server);
    await provider.load();
    await pumpEventQueue();
    await provider.loadMore();
    await pumpEventQueue();

    expect(server.asked, [1, 2]);
    expect(provider.hasMore, isFalse);
  });

  test('une nouvelle recherche oublie les pages préchargées de l’ancienne',
      () async {
    final server = _CatalogServer();
    final provider = MediaRequestsProvider(server);
    await provider.load(query: 'dune');
    await pumpEventQueue();
    server.asked.clear();

    await provider.load(query: 'matrix');
    await pumpEventQueue();
    await provider.loadMore();
    await pumpEventQueue();

    expect(server.asked, [1, 2, 3, 4],
        reason: 'la page 2 de « matrix », pas celle de « dune »');
  });
}
