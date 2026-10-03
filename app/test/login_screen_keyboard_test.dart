import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/device_pairing.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/auth/login_screen.dart';
import 'package:onyx/services/api_client.dart';

/// Records the sign-in attempt and keeps the screen off the network.
class _FakeApiClient extends ApiClient {
  final List<String> logins = [];

  @override
  Future<bool> getSetupRequired() async => false;

  /// The QR sign-in beside the form opens a pairing; refused here, it shows its
  /// failure state and stays off the network.
  @override
  Future<DevicePairing> startDevicePairing({required String deviceName}) async =>
      throw Exception('offline');

  @override
  Future<User> login(String username, String password) async {
    logins.add(username);
    throw Exception('refused');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  Future<_FakeApiClient> pumpLogin(WidgetTester tester) async {
    final apiClient = _FakeApiClient();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: apiClient),
          ChangeNotifierProvider(create: (_) => AuthProvider(apiClient)),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump();
    return apiClient;
  }

  /// Fields in the order they are laid out: server, username, password.
  bool hasFocus(WidgetTester tester, int index) =>
      tester.widget<EditableText>(find.byType(EditableText).at(index))
          .focusNode
          .hasFocus;

  // The television has no pointer, and its keyboard covers the form. If the
  // action key does not move the focus, the fields below the server address are
  // unreachable — which is what the address field's `onEditingComplete` did by
  // replacing Flutter's own handling of that key.
  testWidgets('the keyboard action key walks down the form', (tester) async {
    await pumpLogin(tester);

    await tester.tap(find.byType(TextFormField).first);
    await tester.pump();
    expect(hasFocus(tester, 0), isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(hasFocus(tester, 1), isTrue, reason: 'server → username');

    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(hasFocus(tester, 2), isTrue, reason: 'username → password');
  });

  testWidgets('the last field signs in without reaching for the button',
      (tester) async {
    final apiClient = await pumpLogin(tester);

    await tester.enterText(
        find.byType(TextFormField).at(0), 'http://192.168.1.50:8080');
    await tester.enterText(find.byType(TextFormField).at(1), 'mathis');
    await tester.enterText(find.byType(TextFormField).at(2), 'motdepasse');
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(apiClient.logins, ['mathis']);
    // The keyboard is full screen on a television: it has to go, or the error
    // the sign-in produced is behind it.
    expect(hasFocus(tester, 2), isFalse);
  });

  // Au clavier physique (Windows, web), Entrée dans le mot de passe ne
  // soumettait rien : il fallait aller cliquer sur « Se connecter ».
  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter]) {
    testWidgets('a hardware ${key.keyLabel} in the password signs in',
        (tester) async {
      final apiClient = await pumpLogin(tester);

      await tester.enterText(
          find.byType(TextFormField).at(0), 'http://192.168.1.50:8080');
      await tester.enterText(find.byType(TextFormField).at(1), 'mathis');
      await tester.enterText(find.byType(TextFormField).at(2), 'motdepasse');
      await tester.pump();

      await tester.sendKeyEvent(key);
      await tester.pump();

      expect(apiClient.logins, ['mathis']);
    });
  }

  // 1Password remplissait le mot de passe et laissait l'identifiant vide : aucun
  // champ ne disait ce qu'il était, et l'adresse du serveur passait devant.
  testWidgets('a password manager is told which field is the username',
      (tester) async {
    await pumpLogin(tester);

    Iterable<String>? hints(int index) => tester
        .widget<EditableText>(find.byType(EditableText).at(index))
        .autofillHints;

    expect(hints(0), isNull, reason: 'the server address is not a login');
    expect(hints(1), [AutofillHints.username]);
    expect(hints(2), [AutofillHints.password]);
    expect(
      find.ancestor(
        of: find.byType(EditableText).at(1),
        matching: find.byType(AutofillGroup),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the eye reveals the password and hides it again',
      (tester) async {
    await pumpLogin(tester);

    bool obscured() =>
        tester.widget<EditableText>(find.byType(EditableText).at(2)).obscureText;

    expect(obscured(), isTrue);
    await tester.tap(find.byTooltip('Afficher le mot de passe'));
    await tester.pump();
    expect(obscured(), isFalse);
    await tester.tap(find.byTooltip('Masquer le mot de passe'));
    await tester.pump();
    expect(obscured(), isTrue);
  });
}
