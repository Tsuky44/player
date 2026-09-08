import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/library_provider.dart';
import 'package:onyx/providers/home_provider.dart';
import 'package:onyx/screens/library/movies_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/media_details_cache.dart';

HomeMediaItem movie(String title) => HomeMediaItem.fromJson({
      'id': 1,
      'type': 'movie',
      'title': title,
      'duration': 1200,
    });

class CatalogApi extends ApiClient {
  Future<List<HomeMediaItem>> movies = Future.value([]);
  final status = Completer<IndexerStatus>();
  @override
  Future<List<HomeMediaItem>> getMovies() => movies;
  @override
  Future<List<Media>> getShows() async => [];
  Future<HomeResponse> home = Future.value(HomeResponse.fromJson({}));
  Future<MediaDetails> details = Future.value(MediaDetails.fromJson({'type': 'movie', 'id': 1}));
  @override
  Future<HomeResponse> getHome() => home;
  @override
  Future<MediaDetails> getMediaDetails(int mediaId) => details;
  @override
  Future<IndexerStatus> getIndexerStatus() => status.future;
}

void main() {
  testWidgets('mounted Films tab reloads after switching from an empty server',
      (tester) async {
    final api = CatalogApi();
    final library = LibraryProvider(api);
    await tester.pumpWidget(MultiProvider(providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<LibraryProvider>.value(value: library),
    ], child: const MaterialApp(home: MoviesScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Aucun film'), findsOneWidget);
    api.movies = Future.value([movie('Film du serveur B')]);
    library
        .reset(); // The actual onServerChanged callback resets this provider.
    await tester.pumpAndSettle();
    expect(find.text('Film du serveur B'), findsOneWidget);
    expect(find.text('Aucun film'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    library.dispose();
  });
  test('late response from old server cannot overwrite the new library',
      () async {
    final api = CatalogApi();
    final library = LibraryProvider(api);
    final old = Completer<List<HomeMediaItem>>();
    api.movies = old.future;
    final pending = library.loadMovies();
    api.movies = Future.value([movie('B')]);
    library.reset();
    await library.loadMovies();
    old.complete([movie('A')]);
    await pending;
    expect(library.movies.single.media.title, 'B');
    library.dispose();
  });
  test('home content is displayed without waiting for indexer status',
      () async {
    final api = CatalogApi();
    final home = HomeProvider(api);
    unawaited(home.loadHome());
    await Future<void>.delayed(Duration.zero);
    expect(home.isLoading, false);
    api.status.complete(IndexerStatus.fromJson({}));
    await Future<void>.delayed(Duration.zero);
    home.dispose();
  });
  test('late home response cannot restore the old server after reset',
      () async {
    final api = CatalogApi();
    final home = HomeProvider(api);
    final old = Completer<HomeResponse>();
    api.home = old.future;
    final pending = home.loadHome();
    api.home = Future.value(HomeResponse.fromJson({
      'recent_movies': [
        {'id': 1, 'title': 'B', 'type': 'movie'}
      ]
    }));
    home.reset();
    await Future<void>.delayed(Duration.zero);
    old.complete(HomeResponse.fromJson({
      'recent_movies': [
        {'id': 1, 'title': 'A', 'type': 'movie'}
      ]
    }));
    await pending;
    expect(home.homeData!.recentMovies.single.title, 'B');
    home.dispose();
  });
  test('cleared detail cache cannot be repopulated by an old server', () async {
    MediaDetailsCache.clear();
    final api = CatalogApi();
    final old = Completer<MediaDetails>();
    api.details = old.future;
    final pending = MediaDetailsCache.load(api, 1);
    MediaDetailsCache.clear();
    api.details = Future.value(MediaDetails.fromJson({'type': 'movie', 'id': 1, 'title': 'B'}));
    await MediaDetailsCache.load(api, 1);
    old.complete(MediaDetails.fromJson({'type': 'movie', 'id': 1, 'title': 'A'}));
    await pending;
    expect(MediaDetailsCache.peek(1)!.title, 'B');
    MediaDetailsCache.clear();
  });
}
