import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/navigation/play_link.dart';
import 'package:onyx/services/api_client.dart';

/// Le bouton « Lire » d'une fiche de demande passe par la bibliothèque : un
/// titre qu'elle n'a pas, ou un serveur qui ne répond pas, ne lance rien.
class _IndexApi extends ApiClient {
  _IndexApi(this.index, {this.fails = false});

  final ({Map<int, int> movies, Map<int, int> shows}) index;
  final bool fails;

  @override
  Future<({Map<int, int> movies, Map<int, int> shows})>
      getLibraryTmdbIndex() async {
    if (fails) throw StateError('hors ligne');
    return index;
  }
}

void main() {
  final api = _IndexApi((movies: {603: 7}, shows: {1399: 12}));

  test('un titre de la bibliothèque donne une route de lecture', () async {
    expect(await PlayLink.routeForTmdb(api, MediaType.movie, 603), isNotNull);
    expect(await PlayLink.routeForTmdb(api, MediaType.show, 1399), isNotNull);
  });

  test('un titre absent, ou de l\'autre type, ne donne aucune route', () async {
    expect(await PlayLink.routeForTmdb(api, MediaType.movie, 1399), isNull);
    expect(await PlayLink.routeForTmdb(api, MediaType.show, 603), isNull);
    expect(await PlayLink.routeForTmdb(api, MediaType.movie, 1), isNull);
  });

  test('un serveur qui échoue ne donne aucune route', () async {
    final down = _IndexApi((movies: {}, shows: {}), fails: true);
    expect(await PlayLink.routeForTmdb(down, MediaType.movie, 603), isNull);
  });
}
