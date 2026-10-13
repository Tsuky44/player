import '../../l10n/tr.dart';
import '../../models/models.dart';

/// Les identifiants des onglets de la coquille.
///
/// Des noms et non des rangs : les bibliothèques sont celles que le serveur
/// liste (ADR-0058), leur nombre change d'un serveur à l'autre et pendant
/// qu'on les administre. Un rang désignerait un autre onglet dès qu'une
/// bibliothèque est ajoutée ; un nom garde à chacun son état — monté, défilé,
/// sélectionné, son nœud de focus.
abstract final class ShellTabs {
  static const String home = 'home';
  static const String requests = 'requests';
  static const String downloads = 'downloads';

  static String library(MediaLibrary library) => 'library:${library.id}';

  static bool isLibrary(String tab) => tab.startsWith('library:');

  /// Le nom d'une bibliothèque tel qu'un onglet l'affiche : celui que son
  /// administrateur a choisi. Seules les deux bibliothèques d'un serveur plus
  /// ancien portent un nom de l'app, qui suit donc la langue de l'interface.
  static String label(MediaLibrary library) =>
      library.isLegacy ? tr(library.name) : library.name;
}
