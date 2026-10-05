import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_share.dart';
import 'package:onyx/screens/shared_link/shared_link_guest.dart';
import 'package:onyx/services/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un lien dont le serveur répond sans réseau.
class _Api extends SharedLinkApiClient {
  _Api() : super('AbCdEfGhIjKlMnOpQrStUv', origin: 'https://ami.test');

  @override
  Future<SharedMediaInfo> info() async =>
      const SharedMediaInfo(title: 'Lioness', subtitle: 'Série entière');
}

void main() {
  // L'app installée ne connaît aucun serveur : le lien collé est le seul à
  // dire où il mène (ADR-0037 §9).
  test('un lien collé donne son serveur et son code', () {
    SharedLinkAddress? parse(String raw) => SharedLinkAddress.tryParse(raw);

    final plain = parse('https://ami.test/share#AbC_d-1')!;
    expect(plain.origin, 'https://ami.test');
    expect(plain.code, 'AbC_d-1');

    final local = parse('  http://192.168.1.20:8080/share/#AbC \n')!;
    expect(local.origin, 'http://192.168.1.20:8080');
    expect(local.code, 'AbC');

    final inMessage = parse('Regarde ça : https://ami.test/share#AbC')!;
    expect(inMessage.code, 'AbC', reason: 'copié avec le message autour');

    expect(parse('https://ami.test/onyx/share#AbC')!.origin,
        'https://ami.test/onyx',
        reason: 'un serveur derrière un préfixe le garde');

    expect(parse('https://ami.test/share'), isNull, reason: 'code tronqué');
    expect(parse('https://ami.test/films#AbC'), isNull);
    expect(parse('AbC_d-1'), isNull, reason: 'le code seul ne dit pas où');
    expect(parse(''), isNull);
  });

  // Sans cela la première requête partirait vers la dernière adresse saisie
  // sur cet appareil : le serveur de quelqu'un d'autre.
  test('le client invité vise le serveur du lien, pas celui de l’app', () {
    SharedPreferences.setMockInitialValues({'server_url': 'https://moi.test'});
    final api = SharedLinkApiClient('AbC', origin: 'https://ami.test/');
    expect(api.baseUrl, 'https://ami.test');
    expect(api.isGuest, isTrue);
    expect(api.mediaShareLink('AbC'), 'https://ami.test/share#AbC');
  });

  testWidgets('la page invitée s’ouvre par-dessus l’app et se referme',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SharedLinkGuestScope(api: _Api()),
            )),
            child: const Text('Ouvrir un lien de partage'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Ouvrir un lien de partage'));
    await tester.pumpAndSettle();
    expect(find.text('Lioness'), findsOneWidget);
    expect(find.text('Regarder'), findsOneWidget);

    await tester.tap(find.byTooltip('Fermer'));
    await tester.pumpAndSettle();
    expect(find.text('Lioness'), findsNothing);
    expect(find.text('Ouvrir un lien de partage'), findsOneWidget);
  });
}
