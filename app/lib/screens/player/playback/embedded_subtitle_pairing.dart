import '../../../models/models.dart';
import '../../../services/playback_preferences_storage.dart';
import 'playback_session.dart';

/// Relie les sous-titres que le moteur voit dans le fichier à ceux que le
/// serveur décrit, pour que le client n'ait jamais à déduire lui-même une clé
/// de langue.
///
/// mpv et AetherEngine numérotent les pistes de 1 à N dans l'ordre du
/// conteneur : `id - 1` est l'index typé (`0:s:N`) du serveur. ExoPlayer les
/// désigne par groupe (`2:0`) : lire cet id comme un nombre ne donnait rien,
/// si bien que sur Android un sous-titre choisi n'avait pas de clé — il
/// n'était ni retenu pour la série, ni retrouvé à l'épisode suivant. Sans
/// numéro, c'est le rang dans la liste qui désigne la piste, et quand le
/// moteur n'en liste pas autant que le serveur (un codec qu'il ignore), le
/// rang parmi les pistes de la même langue.
class EmbeddedSubtitlePairing {
  EmbeddedSubtitlePairing._(this._keys, this._tracks);

  factory EmbeddedSubtitlePairing.of(
    List<PlaybackTrack> engine,
    List<MediaSubtitleTrack> canonical,
  ) {
    final real = [
      for (final t in engine)
        if (t.id != 'no' && t.id != 'auto') t,
    ];
    final embedded = [
      for (final s in canonical)
        if (s.typedIndex >= 0) s,
    ]..sort((a, b) => a.typedIndex.compareTo(b.typedIndex));

    final keys = <String, String>{};
    final tracks = <String, PlaybackTrack>{};
    void pair(PlaybackTrack track, MediaSubtitleTrack? entry) {
      if (entry == null) return;
      keys[track.id] = entry.lang;
      tracks.putIfAbsent(entry.lang, () => track);
    }

    final numbered = real.any((t) => int.tryParse(t.id) != null);
    final seenPerLanguage = <String?, int>{};
    for (var i = 0; i < real.length; i++) {
      final track = real[i];
      if (numbered) {
        // Une piste sans numéro est ici celle qu'on a attachée nous-mêmes.
        final sid = int.tryParse(track.id);
        if (sid == null) continue;
        pair(track, _atTypedIndex(embedded, sid - 1));
      } else if (real.length == embedded.length) {
        pair(track, embedded[i]);
      } else {
        final language = _language(track.language);
        final rank = seenPerLanguage.update(language, (n) => n + 1,
            ifAbsent: () => 0);
        final sameLanguage = [
          for (final s in embedded)
            if (_language(s.baseLanguage) == language) s,
        ];
        pair(track, rank < sameLanguage.length ? sameLanguage[rank] : null);
      }
    }
    return EmbeddedSubtitlePairing._(keys, tracks);
  }

  final Map<String, String> _keys;
  final Map<String, PlaybackTrack> _tracks;

  /// La clé canonique (`fr2`, `img3`) de la piste [track] du moteur, ou null
  /// quand le serveur ne la connaît pas.
  String? keyOf(PlaybackTrack track) => _keys[track.id];

  /// La piste du moteur qui porte la clé canonique [key], ou null.
  PlaybackTrack? trackFor(String key) => _tracks[key];

  static MediaSubtitleTrack? _atTypedIndex(
      List<MediaSubtitleTrack> embedded, int typedIndex) {
    for (final s in embedded) {
      if (s.typedIndex == typedIndex) return s;
    }
    return null;
  }

  static String? _language(String? code) =>
      PlaybackPreferencesStorage.normalizeLangCode(code);
}
