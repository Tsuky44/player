import 'package:flutter/foundation.dart';

/// Dit si ce binaire part sur un magasin d'applications (Google Play, App
/// Store) plutôt que d'être distribué par le serveur de l'utilisateur.
///
/// Les magasins interdisent à une app de se mettre à jour hors de chez eux et
/// de proposer ses propres installeurs : un build store coupe donc la mise à
/// jour maison et la page « Applications ». Le drapeau se pose à la
/// compilation (`--dart-define=STORE_BUILD=true`), et `build.gradle.kts` lit
/// le même pour retirer `REQUEST_INSTALL_PACKAGES` du manifeste. Voir
/// l'ADR-0046.
abstract final class StoreBuild {
  static const bool _fromEnvironment = bool.fromEnvironment('STORE_BUILD');

  static bool? _override;

  static bool get enabled => _override ?? _fromEnvironment;

  /// Une constante de compilation ne se change pas d'un test à l'autre.
  @visibleForTesting
  static void overrideForTest(bool? value) => _override = value;
}
