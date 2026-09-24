import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_share.dart';
import 'package:onyx/models/player_layout.dart';
import 'package:onyx/providers/player_layout_provider.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/shared_link/shared_link_app.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un lien dont le serveur répond sans réseau.
class _Api extends SharedLinkApiClient {
  _Api(this._info, {this.refusal}) : super('AbCdEfGhIjKlMnOpQrStUv');

  final SharedMediaInfo _info;
  final SharedLinkException? refusal;

  @override
  Future<SharedMediaInfo> info() async {
    if (refusal != null) throw refusal!;
    return _info;
  }
}

Future<void> _pump(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({});
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

  // Le visiteur voit le playeur maison, pas celui qu'un compte connecté dans
  // ce navigateur aurait choisi.
  test('le lecteur du visiteur est figé sur le Chrome Onyx', () {
    final layout = PlayerLayoutProvider.fixed(
        FixedChromeId.onyx, _Api(const SharedMediaInfo()));
    expect(layout.isLoaded, isTrue);
    expect(layout.fixedChrome, FixedChromeId.onyx);
  });
}
