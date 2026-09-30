import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/library_provider.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/utils/search_match.dart';

class _CatalogApi extends ApiClient {
  _CatalogApi(this.movieTitles, this.showTitles);

  final List<String> movieTitles;
  final List<String> showTitles;

  @override
  Future<List<HomeMediaItem>> getMovies() async => [
        for (var i = 0; i < movieTitles.length; i++)
          HomeMediaItem.fromJson({
            'id': i + 1,
            'type': 'movie',
            'title': movieTitles[i],
            'duration': 6000,
          }),
      ];

  @override
  Future<List<Media>> getShows() async => [
        for (var i = 0; i < showTitles.length; i++)
          Media(
            id: 1000 + i,
            type: MediaType.show,
            title: showTitles[i],
            duration: 0,
            createdAt: DateTime(2026),
          ),
      ];
}

void main() {
  group('foldForSearch', () {
    test('ignore la casse, les accents et les ligatures', () {
      expect(foldForSearch('Amélie'), 'amelie');
      expect(foldForSearch('POKÉMON'), 'pokemon');
      expect(foldForSearch('Cœur'), 'coeur');
      expect(foldForSearch('Ça'), 'ca');
    });

    test('la ponctuation sépare les mots au lieu de les coller', () {
      expect(foldForSearch('Spider-Man : No Way Home'),
          'spider man no way home');
      expect(foldForSearch('L’Empire contre-attaque'),
          'l empire contre attaque');
    });
  });

  group('searchMatchRank', () {
    test('trouve un titre accentué tapé sans accent', () {
      expect(searchMatchRank('Amélie Poulain', 'amelie'), isNotNull);
      expect(searchMatchRank('Pokémon, le film', 'pokemon'), isNotNull);
    });

    test('trouve un titre à trait d’union tapé en un mot ou en deux', () {
      expect(searchMatchRank('Spider-Man', 'spiderman'), isNotNull);
      expect(searchMatchRank('Spider-Man', 'spider man'), isNotNull);
      expect(searchMatchRank('WALL·E', 'walle'), isNotNull);
    });

    test('les mots de la requête peuvent venir dans n’importe quel ordre', () {
      expect(
        searchMatchRank('Star Wars : L’Empire contre-attaque', 'empire star'),
        isNotNull,
      );
    });

    test('ne trouve pas ce qui n’y est pas', () {
      expect(searchMatchRank('Inception', 'amelie'), isNull);
      expect(searchMatchRank('Inception', ''), isNull);
    });

    test('titre exact, puis début de titre, puis début de mot, puis dedans', () {
      final exact = searchMatchRank('Dune', 'dune')!;
      final prefix = searchMatchRank('Dune : Deuxième partie', 'dune')!;
      final word = searchMatchRank('Les Enfants de Dune', 'dune')!;
      final inside = searchMatchRank('Dunes', 'une')!;
      expect(exact, lessThan(prefix));
      expect(prefix, lessThan(word));
      expect(word, lessThan(inside));
    });
  });

  test('le catalogue range les résultats par pertinence, puis par titre',
      () async {
    final library = LibraryProvider(_CatalogApi(
      ['Les Enfants de Dune', 'Dune : Deuxième partie', 'Dune', 'Abyss'],
      ['Dune: Prophecy'],
    ));
    addTearDown(library.dispose);
    await library.ensureCatalogLoaded();

    expect(library.searchCatalog('DUNE').map((m) => m.title), [
      'Dune',
      'Dune : Deuxième partie',
      'Dune: Prophecy',
      'Les Enfants de Dune',
    ]);
  });

  test('le catalogue trouve un titre accentué tapé sans accent', () async {
    final library = LibraryProvider(_CatalogApi(
      ['Le Fabuleux Destin d’Amélie Poulain'],
      ['Pokémon'],
    ));
    addTearDown(library.dispose);
    await library.ensureCatalogLoaded();

    expect(library.searchCatalog('amelie').single.title,
        'Le Fabuleux Destin d’Amélie Poulain');
    expect(library.searchCatalog('pokemon').single.title, 'Pokémon');
  });
}
