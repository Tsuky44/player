import 'dart:async';

import 'package:onyx/services/server_scheme.dart';

/// Configuration commune à tous les tests.
///
/// Le choix de HTTPS (ADR-0080) sonde le serveur par le réseau à chaque
/// adresse fixée. Un test ne touche pas au réseau, et sous le temps simulé des
/// tests d'écran la sonde n'aboutissait jamais : la connexion restait
/// suspendue. Ici aucun serveur ne parle HTTPS ; les tests de
/// `server_scheme_test.dart` posent leur propre sonde.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  ServerScheme.instance = ServerScheme(probe: (_) async => false);
  await testMain();
}
