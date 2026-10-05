import '../../../models/models.dart';
import '../../../models/series_track_preferences.dart';

/// Le sous-titre choisi dans un épisode, décrit de façon à le retrouver dans le
/// suivant.
///
/// La clé seule ne suffit pas : le serveur l'attribue dans l'ordre du fichier
/// (`fr`, puis `fr2` pour une deuxième piste française), si bien que la même clé
/// désigne la piste complète dans un épisode et la forcée dans l'autre. On
/// retrouve donc la piste par ce qui ne bouge pas d'un fichier à l'autre : sa
/// langue et le fait qu'elle soit forcée ou non.
class CarriedSubtitle {
  const CarriedSubtitle({
    required this.key,
    required this.language,
    this.forced = false,
    this.image = false,
  });

  /// Depuis la piste canonique du média qu'on quitte.
  factory CarriedSubtitle.of(MediaSubtitleTrack track) => CarriedSubtitle(
        key: track.lang,
        language: track.baseLanguage,
        forced: track.forced,
        image: track.image,
      );

  /// Quand le média qu'on quitte ne connaissait que la clé, faute de liste des
  /// pistes : on ne sait alors rien de plus que ce qu'elle laisse deviner.
  factory CarriedSubtitle.fromKey(String key) => CarriedSubtitle.of(
      MediaSubtitleTrack(lang: key, name: '', image: key.startsWith('img')));

  /// Depuis le choix que le compte a retenu pour la série (ADR-0044).
  factory CarriedSubtitle.fromSeries(SeriesSubtitleChoice choice) =>
      CarriedSubtitle(
        key: choice.key,
        language: choice.language,
        forced: choice.forced,
        image: choice.image,
      );

  /// Le même choix, sous la forme que le compte retient pour la série.
  SeriesSubtitleChoice get asSeriesChoice => SeriesSubtitleChoice(
        language: language,
        key: key,
        forced: forced,
        image: image,
      );

  /// Clé canonique dans le média d'origine (`fr2`, `img3`).
  final String key;

  /// Langue de base (`fr`), vide quand elle est inconnue.
  final String language;

  final bool forced;
  final bool image;

  /// La piste de [subtitles] qui tient ce choix, ou null si le média n'en a
  /// aucune.
  ///
  /// Forcée ou complète doit correspondre, dans les deux sens : une piste
  /// forcée ne sous-titre que les dialogues étrangers, une complète tout le
  /// reste. Substituer l'une à l'autre, c'est ce qui faisait « repasser en
  /// French » un épisode réglé en « French Forced ». Parmi les pistes qui
  /// conviennent, la même clé d'abord (même fichier, même découpage), puis le
  /// même rendu (texte ou image).
  MediaSubtitleTrack? matchIn(List<MediaSubtitleTrack> subtitles) {
    final candidates = [
      for (final s in subtitles)
        if (s.forced == forced && _sameLanguage(s)) s,
    ];
    if (candidates.isEmpty) return null;
    for (final s in candidates) {
      if (s.lang == key) return s;
    }
    for (final s in candidates) {
      if (s.image == image) return s;
    }
    return candidates.first;
  }

  /// Sans langue connue, seule la clé exacte peut désigner la même piste.
  bool _sameLanguage(MediaSubtitleTrack track) =>
      language.isEmpty ? track.lang == key : track.baseLanguage == language;
}
