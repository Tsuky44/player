import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/services/server_registry.dart';

/// Deux comptes en mémoire, liés ou non, avec un jeton propre à chacun.
class Registry extends ServerRegistry {
  bool linked = true;
  @override
  List<ServerAccount> linkedAccounts(String id) =>
      linked ? accounts : accounts.where((a) => a.id == id).toList();
  @override
  List<ServerAccount> get accounts => const [
        ServerAccount(id: 'a', url: 'http://a.test', username: 'one'),
        ServerAccount(id: 'b', url: 'http://b.test', username: 'two'),
      ];
  @override
  ServerAccount? accountById(String id) =>
      accounts.where((a) => a.id == id).firstOrNull;
  @override
  Future<String?> tokenFor(String id) async => 'token-$id';
}

class Adapter implements HttpClientAdapter {
  Adapter(this.handle);
  final ResponseBody Function(RequestOptions) handle;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      handle(options);
  @override
  void close({bool force = false}) {}
}
