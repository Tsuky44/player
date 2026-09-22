/// Un sous-titre WebVTT, découpé une fois pour être affiché au fil de la
/// lecture par un moteur qui ne sait pas le faire lui-même.
///
/// ExoPlayer et mpv reçoivent le WebVTT du serveur et le rendent. AVPlayer ne
/// prend de sous-titres qu'intégrés au flux HLS ; ceux que le serveur produit
/// à part sont donc découpés ici et peints par `SubtitleOverlay`, avec le même
/// habillage que sur Android.
library;

/// Une réplique : ses lignes, et quand elles sont à l'écran.
class VttCue {
  const VttCue(this.start, this.end, this.lines);

  final Duration start;
  final Duration end;
  final List<String> lines;
}

/// Les répliques d'un fichier, triées, interrogeables par position.
class VttCues {
  VttCues._(this._cues);

  /// Découpe [content]. Ce qui ne se lit pas est sauté plutôt que fatal : un
  /// sous-titre dont une réplique est mal formée reste utile pour les autres.
  factory VttCues.parse(String content) {
    final cues = <VttCue>[];
    final blocks = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split(RegExp(r'\n{2,}'));
    for (final block in blocks) {
      final lines = block.split('\n');
      final timing = lines.indexWhere((line) => line.contains('-->'));
      if (timing < 0) continue; // WEBVTT, NOTE, STYLE, REGION…
      final arrow = lines[timing].split('-->');
      final start = parseVttTimestamp(arrow[0]);
      // Après l'heure de fin viennent les réglages de position : `line:90%`.
      final end =
          parseVttTimestamp(arrow[1].trim().split(RegExp(r'\s+')).first);
      if (start == null || end == null || end <= start) continue;
      final text = [
        for (final line in lines.skip(timing + 1))
          if (_stripTags(line).trim().isNotEmpty) _stripTags(line).trim(),
      ];
      if (text.isEmpty) continue;
      cues.add(VttCue(start, end, text));
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return VttCues._(cues);
  }

  static final VttCues empty = VttCues._(const []);

  final List<VttCue> _cues;

  bool get isEmpty => _cues.isEmpty;

  /// Les lignes à l'écran à [position]. Plusieurs répliques peuvent se
  /// chevaucher (deux personnages qui parlent en même temps) : elles
  /// s'empilent dans l'ordre du fichier.
  List<String> linesAt(Duration position) {
    // La première réplique qui commence après [position] borne la recherche ;
    // tout ce qui est avant et pas encore fini est à l'écran.
    var hi = _cues.length;
    var lo = 0;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_cues[mid].start <= position) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final lines = <String>[];
    // Remonter tant qu'une réplique antérieure peut encore durer. Une borne
    // fixe suffit : des répliques de plus d'une minute n'existent pas.
    for (var i = lo - 1; i >= 0; i--) {
      final cue = _cues[i];
      if (position - cue.start > const Duration(minutes: 1)) break;
      if (cue.end > position) lines.insertAll(0, cue.lines);
    }
    return lines;
  }

  static final RegExp _tag = RegExp(r'<[^>]*>');

  /// `<i>`, `<b>`, `<c.yellow>`, `<v Bob>` : la mise en forme n'est pas
  /// rendue, le texte si.
  static String _stripTags(String line) => line
      .replaceAll(_tag, '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
}

/// `01:02:03.456` ou `02:03.456`, en durée. Null si ce n'en est pas une.
Duration? parseVttTimestamp(String raw) {
  final parts = raw.trim().replaceAll(',', '.').split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final secondsPart = parts.last.split('.');
  final hours = parts.length == 3 ? int.tryParse(parts[0]) : 0;
  final minutes = int.tryParse(parts[parts.length - 2]);
  final seconds = int.tryParse(secondsPart[0]);
  final millis = secondsPart.length > 1
      ? int.tryParse(secondsPart[1].padRight(3, '0').substring(0, 3))
      : 0;
  if (hours == null || minutes == null || seconds == null || millis == null) {
    return null;
  }
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: millis,
  );
}
