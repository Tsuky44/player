import 'app_language.dart';
import 'en.dart';

/// Rend [fr] dans la langue de l'app.
///
/// Le texte français écrit dans le code est la clé : on écrit l'interface en
/// français, comme avant, et [kEnglish] porte sa traduction. Une clé sans
/// traduction retombe sur le français plutôt que sur un trou — et
/// `test/l10n_coverage_test.dart` échoue tant qu'elle manque. Voir l'ADR-0047.
///
/// Les valeurs variables passent par [args] et se placent avec `{0}`, `{1}`… :
/// une phrase interpolée (`'Bonjour $nom'`) aurait une clé différente à chaque
/// valeur, donc aucune traduction possible.
String tr(String fr, [List<Object?> args = const []]) {
  final template =
      AppLanguage.current == AppLanguage.english ? (kEnglish[fr] ?? fr) : fr;
  if (args.isEmpty) return template;
  return template.replaceAllMapped(_placeholder, (match) {
    final index = int.parse(match.group(1)!);
    return index < args.length ? '${args[index]}' : match.group(0)!;
  });
}

final RegExp _placeholder = RegExp(r'\{(\d+)\}');
