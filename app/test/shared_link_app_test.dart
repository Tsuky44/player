import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_share.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/shared_link/shared_link_app.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un lien dont le serveur répond sans réseau.
class _Api extends SharedLinkApiClient {
  _Api(this._info, {this.refusal, this.unlocked})
      : super('AbCdEfGhIjKlMnOpQrStUv');

  final SharedMediaInfo _info;
  final SharedLinkException? refusal;

  /// Ce que le lien décrit une fois son mot de passe donné.
  final SharedMediaInfo? unlocked;

  /// Les épisodes dont l'ouverture a été demandée.
  final List<int?> opened = [];

  @override
  Future<SharedMediaInfo> info() async {
    if (refusal != null) throw refusal!;
    return _info;
  }

  @override
  Future<SharedMediaInfo> contents(String password) async {
    if (password != 'popcorn') {
      throw const SharedLinkException(401, 'Mot de passe incorrect.');
    }
    return unlocked!;
  }

  // L'ouverture s'arrête ici : le lecteur lui-même n'est pas l'objet du test.
  @override
  Future<({SharedMediaInfo media, int mediaId})> open(String password,
      {int? episodeId}) async {
    opened.add(episodeId);
    throw const SharedLinkException(0, 'Serveur injoignable.');
  }
}

const _season = SharedMediaInfo(
  mediaType: 'season',
  title: 'Lioness',
  subtitle: 'Saison 1',
  episodes: [
    SharedEpisode(
        id: 11,
        seasonId: 2,
        seasonNumber: 1,
        episodeNumber: 1,
        title: 'Pilote',
        duration: 3000),
    SharedEpisode(
        id: 15,
        seasonId: 2,
        seasonNumber: 1,
        episodeNumber: 5,
        title: 'Fin',
        duration: 3000),
  ],
);

Future<void> _pump(WidgetTester tester, _Api api,
    {Map<String, Object> stored = const {}}) async {
  SharedPreferences.setMockInitialValues(stored);
  // Assez haut pour que la liste des épisodes, sous l'en-tête de la fiche,
  // soit construite.
  await tester.binding.setSurfaceSize(const Size(1280, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final auth = AuthProvider(api);
  addTearDown(auth.dispose);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
    ],
    child: SharedLinkApp(api: api),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  test('le code du lien vient du fragment de /share', () {
    String? code(String url) => parseSharedLinkCode(Uri.parse(url));
    expect(code('https://onyx.test/share#AbC_d-1'), 'AbC_d-1');
    expect(code('https://onyx.test/share/#AbC'), 'AbC');
    // Réécrit par le routeur de Flutter en #/code.
    expect(code('https://onyx.test/share#/AbC'), 'AbC');
    expect(code('https://onyx.test/share'), '',
        reason: 'adresse tronquée : la page le dit');
    expect(code('https://onyx.test/'), isNull);
    expect(code('https://onyx.test/films#AbC'), isNull);
  });

  testWidgets(
      'un lien sans mot de passe montre son média et le bouton Regarder',
      (tester) async {
    await _pump(
        tester,
        _Api(const SharedMediaInfo(
            title: 'Lioness', subtitle: 'S01E05 · Cinq cent enfants')));
    expect(find.text('Lioness'), findsOneWidget);
    expect(find.text('S01E05 · Cinq cent enfants'), findsOneWidget);
    expect(find.text('Regarder'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('un lien protégé demande son mot de passe sans nommer le média',
      (tester) async {
    await _pump(tester, _Api(const SharedMediaInfo(needsPassword: true)));
    expect(find.text('Contenu protégé'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  // Le lien d'une saison ou d'une série a la fiche d'un compte : un bouton
  // qui lance le premier épisode, et la liste d'où choisir les autres. C'est
  // l'épisode choisi que le serveur ouvre.
  testWidgets('le lien d’une saison montre sa fiche et ouvre l’épisode choisi',
      (tester) async {
    final api = _Api(_season);
    await _pump(tester, api);
    expect(find.text('Lioness'), findsOneWidget);
    expect(find.text('Lecture S1 E1'), findsOneWidget);
    expect(find.text('Pilote'), findsOneWidget);
    expect(find.text('2 disponibles'), findsOneWidget);
    expect(find.text('Regarder'), findsNothing);
    expect(find.byTooltip('Télécharger'), findsNothing,
        reason: 'un visiteur regarde, il n’emporte rien');

    await tester.tap(find.text('Fin'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.opened, [15]);
    expect(find.text('Serveur injoignable.'), findsOneWidget);
    expect(find.text('Pilote'), findsOneWidget,
        reason: 'un échec laisse la liste : un autre épisode reste à choisir');
  });

  // Ce que l'appareil a retenu du lien : le visiteur retrouve « Reprendre »
  // sur l'épisode entamé, comme avec un compte.
  testWidgets('un visiteur revenu sur le lien reprend son épisode',
      (tester) async {
    final api = _Api(_season);
    await _pump(tester, api, stored: {
      'onyx-share-last:AbCdEfGhIjKlMnOpQrStUv': 15,
      'onyx-share-position:AbCdEfGhIjKlMnOpQrStUv:15': 600,
      'onyx-share-finished:AbCdEfGhIjKlMnOpQrStUv': <String>['11'],
    });
    expect(find.text('Reprendre S1 E5'), findsOneWidget);

    await tester.tap(find.text('Reprendre S1 E5'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.opened, [15]);
  });

  testWidgets(
      'une série protégée ne montre ses épisodes qu’une fois le mot de passe donné',
      (tester) async {
    final api = _Api(const SharedMediaInfo(needsPassword: true),
        unlocked: const SharedMediaInfo(
          needsPassword: true,
          mediaType: 'show',
          title: 'Lioness',
          subtitle: 'Série entière',
          episodes: [
            SharedEpisode(
                id: 11, seasonId: 2, seasonNumber: 1, episodeNumber: 1),
            SharedEpisode(
                id: 21, seasonId: 5, seasonNumber: 2, episodeNumber: 1),
          ],
        ));
    await _pump(tester, api);
    expect(find.text('Contenu protégé'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.text('Ouvrir'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Mot de passe incorrect.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'popcorn');
    await tester.tap(find.text('Ouvrir'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Lioness'), findsOneWidget);
    expect(find.text('Saison 1'), findsOneWidget);
    expect(find.text('Saison 2'), findsOneWidget,
        reason: 'plusieurs saisons : chacune a son onglet');
    expect(find.text('Épisode 1'), findsOneWidget,
        reason: 'seule la saison choisie est listée');
    expect(find.byType(TextField), findsNothing);
    expect(api.opened, isEmpty,
        reason: 'lister les épisodes ne délivre aucun ticket');
  });

  testWidgets('un lien vu dit qu’il n’est plus disponible', (tester) async {
    await _pump(
        tester,
        _Api(const SharedMediaInfo(),
            refusal: const SharedLinkException(
                410, 'Ce lien a expiré ou a déjà été utilisé.')));
    expect(find.text('Lien indisponible'), findsOneWidget);
    expect(
        find.text('Ce lien a expiré ou a déjà été utilisé.'), findsOneWidget);
    expect(find.text('Regarder'), findsNothing);
  });
}
