/// Le sous-titre choisi pour une série, décrit par ce qui ne bouge pas d'un
/// épisode à l'autre (ADR-0044).
class SeriesSubtitleChoice {
  /// Sous-titres désactivés : un choix à part entière, qui suit lui aussi.
  final bool off;

  /// Langue de base (`fr`), vide quand la piste d'origine n'en portait pas.
  final String language;

  /// Clé canonique dans l'épisode où le choix a été fait (`fr2`, `img3`).
  final String key;

  final bool forced;
  final bool image;

  const SeriesSubtitleChoice({
    required this.language,
    required this.key,
    this.forced = false,
    this.image = false,
  }) : off = false;

  const SeriesSubtitleChoice.off()
      : off = true,
        language = '',
        key = '',
        forced = false,
        image = false;

  /// Null quand le serveur ne tient aucun choix (`mode` vide).
  static SeriesSubtitleChoice? fromJson(Object? json) {
    if (json is! Map) return null;
    switch (json['mode']) {
      case 'off':
        return const SeriesSubtitleChoice.off();
      case 'on':
        return SeriesSubtitleChoice(
          language: (json['lang'] as String?) ?? '',
          key: (json['key'] as String?) ?? '',
          forced: json['forced'] == true,
          image: json['image'] == true,
        );
    }
    return null;
  }

  Map<String, Object> toJson() => off
      ? {'mode': 'off'}
      : {
          'mode': 'on',
          'lang': language,
          'key': key,
          'forced': forced,
          'image': image,
        };
}

/// La langue audio et le sous-titre qu'un compte a choisis pour une série,
/// tels que le serveur les tient (ADR-0044).
class SeriesTrackPreferences {
  /// Code ISO à deux lettres, ou null tant qu'aucune piste n'a été choisie.
  final String? audioLang;

  /// Null tant que rien n'a été choisi pour les sous-titres de cette série.
  final SeriesSubtitleChoice? subtitle;

  const SeriesTrackPreferences({this.audioLang, this.subtitle});

  bool get isEmpty => audioLang == null && subtitle == null;

  factory SeriesTrackPreferences.fromJson(Map<String, dynamic> json) {
    final lang = (json['audio_lang'] as String?)?.trim() ?? '';
    return SeriesTrackPreferences(
      audioLang: lang.isEmpty ? null : lang,
      subtitle: SeriesSubtitleChoice.fromJson(json['subtitle']),
    );
  }

  /// La forme du serveur, pour la copie gardée sur l'appareil.
  Map<String, Object> toJson() => {
        'audio_lang': audioLang ?? '',
        if (subtitle != null) 'subtitle': subtitle!.toJson(),
      };

  SeriesTrackPreferences withAudioLang(String lang) =>
      SeriesTrackPreferences(audioLang: lang, subtitle: subtitle);

  SeriesTrackPreferences withSubtitle(SeriesSubtitleChoice choice) =>
      SeriesTrackPreferences(audioLang: audioLang, subtitle: choice);
}
