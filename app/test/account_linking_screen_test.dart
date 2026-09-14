import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/settings/servers_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/server_registry.dart';

import 'test_doubles.dart' show Adapter;

/// Un serveur factice par compte : les liens qu'il déclare sont ce que l'écran
/// affiche, comme le ferait `GET /api/links`.
class LinkingApi extends ApiClient {
  LinkingApi(ServerRegistry registry) : super(registry: registry);
  final linked = <String, List<AccountLink>>{};

  @override
  Future<void> refreshAccountLinks() async {
    for (final account in servers.accounts) {
      await servers.setServerLinks(account.id, linked[account.id] ?? const []);
    }
  }

  @override
  Future<AccountLink> linkAccounts(String fromId, String toId,
      {bool refresh = true}) async {
    final to = servers.accountById(toId)!;
    final link = AccountLink(
      id: 1,
      serverId: '',
      serverName: '',
      url: to.url,
      remoteUserId: 0,
      remoteUsername: to.username,
    );
    linked[fromId] = [link];
    await refreshAccountLinks();
    return link;
  }

  @override
  Future<void> unlinkAccount(String accountId, AccountLink link) async {
    linked.remove(accountId);
    await refreshAccountLinks();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
  });

  testWidgets(
      'different usernames can be linked and detached from the servers screen',
      (tester) async {
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
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Options du compte alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lier un compte'));
    await tester.pumpAndSettle();
    expect(find.text('Lier alice à un compte'), findsOneWidget);
    await tester.tap(find.text('bob · b.local'));
    await tester.pumpAndSettle();
    expect(registry.linkedAccounts(a.id).map((a) => a.id), contains(b.id));
    expect(find.textContaining('Lié à bob'), findsOneWidget);
    expect(find.textContaining('en attente des administrateurs'), findsOneWidget);
    await tester.tap(find.byTooltip('Options du compte alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dissocier ce compte'));
    await tester.pumpAndSettle();
    expect(registry.linkedAccounts(a.id), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  // Le lien est tenu par le serveur : un autre appareil, connecté au seul
  // premier serveur, voit le second et peut s'y connecter.
  testWidgets('a server linked from another device is offered for sign-in',
      (tester) async {
    final registry = ServerRegistry();
    await registry.load();
    final a = await registry.remember(
        url: 'http://a.local', username: 'alice', token: 'a');
    final api = LinkingApi(registry)
      ..linked[a.id] = const [
        AccountLink(
          id: 3,
          serverId: 'paul',
          serverName: 'Chez Paul',
          url: 'http://paul.example:8080',
          remoteUserId: 12,
          remoteUsername: 'alice2',
          status: 'active',
        ),
      ];
    final auth = AuthProvider(api);
    await tester.pumpWidget(MultiProvider(providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
    ], child: const MaterialApp(home: ServersScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Vos autres serveurs'), findsOneWidget);
    expect(find.text('Chez Paul'), findsOneWidget);
    await tester.tap(find.text('Se connecter'));
    await tester.pumpAndSettle();
    expect(find.text('http://paul.example:8080'), findsOneWidget);
    expect(find.text('alice2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  test('linking sends each token only to its own server', () async {
    final registry = ServerRegistry();
    await registry.load();
    final a = await registry.remember(
        url: 'http://a.local', username: 'alice', token: 'token-a');
    final b = await registry.remember(
        url: 'http://b.local', username: 'bob', token: 'token-b');
    final seen = <String>[];
    Map? posted;
    final api = ApiClient(registry: registry)
      ..clientFactory = (options) => Dio(options)
        ..httpClientAdapter = Adapter((r) {
          seen.add('${r.baseUrl}${r.path} ${r.headers['Authorization']}');
          if (r.path == '/api/links') posted = r.data as Map;
          final body = switch (r.path) {
            '/api/links/code' => {'code': 'proof'},
            '/api/links' => {
                'id': 5,
                'server_id': 'b',
                'server_name': 'B',
                'url': r.data['url'],
                'remote_user_id': 2,
                'remote_username': 'bob',
                'status': 'pending',
              },
            _ => <String, dynamic>{},
          };
          return ResponseBody.fromString(jsonEncode(body), 200, headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
        });
    final link = await api.linkAccounts(a.id, b.id, refresh: false);
    expect(link.url, 'http://b.local');
    expect(posted, {
      'url': 'http://b.local',
      'self_url': 'http://a.local',
      'code': 'proof',
    });
    expect(seen, [
      'http://b.local/api/links/code Bearer token-b',
      'http://a.local/api/links Bearer token-a',
    ]);
  });
}
