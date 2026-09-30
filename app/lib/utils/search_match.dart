/// La correspondance entre un titre et ce qu'on tape pour le trouver.
///
/// La recherche du catalogue comparait `title.toLowerCase().contains(q)` : on
/// ne trouvait « Amélie » qu'en tapant l'accent, geste que presque personne ne
/// fait sur un clavier de téléphone et qu'aucune télécommande ne facilite, et
/// « spiderman » ne trouvait pas « Spider-Man ». Les résultats sortaient par
/// ordre alphabétique : « Les Enfants de Dune » passait devant « Dune ».
library;

/// Les lettres accentuées et les ligatures, ramenées à leur forme de base.
const Map<String, String> _folds = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'æ': 'ae',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ę': 'e',
  'ě': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ō': 'o',
  'œ': 'oe',
  'ß': 'ss',
  'š': 's',
  'ś': 's',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'ł': 'l',
};

final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// [text] tel que la recherche le compare : en minuscules, sans accents, la
/// ponctuation changée en espace et les espaces réduits à un seul.
///
/// La ponctuation sépare au lieu de disparaître : « L’Empire » doit se
/// trouver par « empire », ce qu'il ne ferait pas collé en « lempire ».
String foldForSearch(String text) {
  final buffer = StringBuffer();
  var pendingSpace = false;
  for (final char in text.toLowerCase().split('')) {
    final folded = _folds[char] ?? char;
    if (_wordChar.hasMatch(folded)) {
      if (pendingSpace && buffer.isNotEmpty) buffer.write(' ');
      pendingSpace = false;
      buffer.write(folded);
    } else {
      pendingSpace = true;
    }
  }
  return buffer.toString();
}

/// Articles ignorés en tête d'un titre pour le ranger : « Le Parrain » va
/// aux P, « The Batman » aux B, comme dans une vidéothèque.
final RegExp _leadingArticle =
    RegExp(r'^(le|la|les|l|un|une|des|the|a|an) (?=.)');

/// La clé qui range [title] dans un tri A → Z.
///
/// `compareTo` sur le titre brut comparait les unités UTF-16 : « Éternels »
/// passait après « Zodiac » et « amour » après toutes les majuscules.
String titleSortKey(String title) =>
    foldForSearch(title).replaceFirst(_leadingArticle, '');

/// Le rang de [title] pour la requête [query] : plus petit, plus pertinent.
/// Null quand le titre ne correspond pas.
///
/// Dans l'ordre : le titre exact, un titre qui commence par la requête, un mot
/// du titre qui commence par elle, tous les mots de la requête en début de mots
/// du titre (dans n'importe quel ordre), la requête n'importe où, et enfin la
/// requête sans ses espaces dans le titre sans les siens — c'est ce dernier qui
/// fait trouver « Spider-Man » par « spiderman » et « WALL·E » par « walle ».
int? searchMatchRank(String title, String query) {
  final q = foldForSearch(query);
  if (q.isEmpty) return null;
  final t = foldForSearch(title);

  if (t == q) return 0;
  if (t.startsWith(q)) return 1;
  if (' $t'.contains(' $q')) return 2;

  final titleWords = t.split(' ');
  final queryWords = q.split(' ');
  if (queryWords.every(
      (word) => titleWords.any((titleWord) => titleWord.startsWith(word)))) {
    return 3;
  }

  if (t.contains(q)) return 4;
  if (t.replaceAll(' ', '').contains(q.replaceAll(' ', ''))) return 5;
  return null;
}
