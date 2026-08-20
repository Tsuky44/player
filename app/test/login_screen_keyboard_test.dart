import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/auth/login_screen.dart';
import 'package:onyx/services/api_client.dart';

/// Records the sign-in attempt and keeps the screen off the network.
class _FakeApiClient extends ApiClient {
  final List<String> logins = [];

  @override
  Future<bool> getSetupRequired() async => false;

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
}
