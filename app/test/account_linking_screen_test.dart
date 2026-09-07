import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/settings/servers_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/server_registry.dart';

class LinkingApi extends ApiClient {
  LinkingApi(ServerRegistry registry) : super(registry: registry);
  @override
  Future<void> synchronizeLinkedProgress() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'different usernames can be linked and detached from the servers screen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    final registry = ServerRegistry();
    await registry.load();
    final a = await registry.remember(
        url: 'http://a.local', username: 'alice', token: 'a');
    final b = await registry.remember(
        url: 'http://b.local', username: 'bob', token: 'b');
    final api = LinkingApi(registry);
    final auth = AuthProvider(api);
    await tester.pumpWidget(MultiProvider(providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
    ], child: const MaterialApp(home: ServersScreen())));
    await tester.tap(find.byTooltip('Options du compte alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lier un compte'));
    await tester.pumpAndSettle();
    expect(find.text('Lier alice à un compte'), findsOneWidget);
    await tester.tap(find.text('bob · b.local'));
    await tester.pumpAndSettle();
    expect(registry.linkedAccounts(a.id).map((a) => a.id), contains(b.id));
    expect(find.textContaining('Lié à bob'), findsOneWidget);
    await tester.tap(find.byTooltip('Options du compte alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dissocier ce compte'));
    await tester.pumpAndSettle();
    expect(registry.linkedAccounts(a.id), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
}
