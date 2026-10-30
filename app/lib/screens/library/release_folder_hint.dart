/// Le dossier de release que laissent deviner les chemins de fichiers d'une
/// série : le premier segment parent qui n'est ni un dossier de saison
/// (`Season 1`, `Saison 2`) ni un nom d'épisode (`S01E02`).
///
/// [filePaths] suit l'ordre de préférence ; les chemins vides ou null sont
/// ignorés.
String? releaseFolderHint(Iterable<String?> filePaths) {
  final episodeTag = RegExp(r's\d{1,2}e\d{1,3}', caseSensitive: false);
  for (final path in filePaths) {
    if (path == null || path.isEmpty) continue;
    final segments = path.replaceAll('\\', '/').split('/')
      ..removeWhere((s) => s.trim().isEmpty);
    if (segments.length < 2) continue;
    for (var i = segments.length - 2; i >= 0; i--) {
      final part = segments[i].trim();
      if (part.isEmpty) continue;
      final lower = part.toLowerCase();
      if (lower.startsWith('season ') || lower.startsWith('saison ')) continue;
      if (episodeTag.hasMatch(part)) continue;
      return part;
    }
  }
  return null;
}
