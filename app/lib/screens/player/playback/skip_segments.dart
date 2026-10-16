/// Ce que le bouton « Passer » propose de sauter. Le récap précède l'intro
/// et se propose à part : on peut vouloir revoir l'un sans l'autre, et chacun
/// a son propre réglage de saut automatique.
enum SkipSegment { recap, intro }

/// Classe les chapitres MKV d'après leur titre. Les mêmes règles que
/// `server/indexer/detection.go`, à ceci près que le serveur n'a pas de récap :
/// il ne range qu'une intro.
abstract final class ChapterTitles {
  static bool isRecap(String title) {
    final t = _normalize(title);
    if (t.isEmpty) return false;
    const keywords = ['recap', 'previously on', 'precedemment'];
    return keywords.any((kw) => _matches(t, kw));
  }

  /// Un chapitre de récap n'est jamais une intro : les confondre faisait
  /// sauter le récap sous le nom « intro », puis laissait passer l'intro.
  static bool isIntro(String title) {
    final t = _normalize(title);
    if (t.isEmpty || isRecap(title)) return false;
    if (_isOpeningCredits(t)) return true;
    const keywords = [
      'intro', 'opening',
      'generique de debut', 'generique debut',
    ];
    for (final kw in keywords) {
      if (_matches(t, kw)) return true;
    }
    return _matches(t, 'op');
  }

  static bool isOutro(String title) {
    final t = _normalize(title);
    if (t.isEmpty) return false;
    if (_isClosingCredits(t)) return true;
    const keywords = [
      'outro', 'ending',
      'generique de fin', 'generique fin',
    ];
    for (final kw in keywords) {
      if (_matches(t, kw)) return true;
    }
    return _matches(t, 'ed');
  }

  static String _normalize(String title) {
    const accents = {
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'à': 'a', 'â': 'a', 'ä': 'a',
      'î': 'i', 'ï': 'i',
      'ô': 'o', 'ö': 'o',
      'û': 'u', 'ü': 'u', 'ù': 'u',
      'ç': 'c',
    };
    var t = title.toLowerCase().trim();
    accents.forEach((from, to) {
      t = t.replaceAll(from, to);
    });
    return t;
  }

  static bool _matches(String normTitle, String keyword) {
    if (keyword == 'op' || keyword == 'ed') {
      if (normTitle == keyword) return true;
      return normTitle.startsWith('$keyword ') || normTitle.endsWith(' $keyword');
    }
    return normTitle.contains(keyword);
  }

  static bool _isOpeningCredits(String t) {
    if (t.contains('opencreditstart') || t.contains('open_credit_start')) {
      return true;
    }
    if (t.contains('open') && t.contains('credit') && t.contains('start')) {
      return true;
    }
    if (t.contains('opening') && t.contains('credit')) return true;
    return false;
  }

  static bool _isClosingCredits(String t) {
    if (_isOpeningCredits(t)) return false;
    if (t.contains('open') && t.contains('credit')) return false;
    if (t == 'credits' || t == 'credit') return true;
    if (t.contains('credits')) return true;
    return false;
  }
}
