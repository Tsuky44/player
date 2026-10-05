/// Le réglage de « Vous regardez encore ? » (ADR-0045) : quand le lecteur
/// cesse d'enchaîner les épisodes tout seul pour attendre une réponse.
///
/// Il appartient au compte, comme les autres préférences de lecture
/// (ADR-0043). Seule l'heure est celle de l'appareil : « entre 22 h et 6 h »
/// veut dire la nuit de celui qui regarde, pas celle du serveur.
class StillWatchingSettings {
  final bool enabled;

  /// Le nombre d'épisodes enchaînés sans que personne ne touche au lecteur
  /// au bout duquel la question est posée, de 1 à [maxEpisodes].
  final int episodes;

  /// La plage où la question se pose, en minutes depuis minuit. Elle peut
  /// passer minuit. [allDayMinute] pour les deux : toute la journée.
  final int fromMinute;
  final int untilMinute;

  const StillWatchingSettings({
    this.enabled = true,
    this.episodes = 3,
    this.fromMinute = allDayMinute,
    this.untilMinute = allDayMinute,
  });

  /// Les mêmes valeurs que les défauts du serveur : un compte qui n'a rien
  /// choisi est protégé du binge endormi sans avoir à trouver le réglage.
  static const StillWatchingSettings defaults = StillWatchingSettings();

  static const int allDayMinute = -1;
  static const int maxEpisodes = 10;

  /// La plage proposée quand on restreint la question pour la première fois :
  /// la nuit, c'est le cas qui a fait naître le réglage.
  static const int defaultFromMinute = 22 * 60;
  static const int defaultUntilMinute = 6 * 60;

  bool get allDay => fromMinute < 0 || untilMinute < 0;

  /// La question se pose-t-elle à cette heure ?
  bool appliesAt(DateTime now) {
    if (!enabled) return false;
    if (allDay) return true;
    final minute = now.hour * 60 + now.minute;
    if (fromMinute < untilMinute) {
      return minute >= fromMinute && minute < untilMinute;
    }
    // La plage passe minuit : 22 h → 6 h couvre la fin d'un jour et le début
    // du suivant.
    return minute >= fromMinute || minute < untilMinute;
  }

  StillWatchingSettings copyWith({
    bool? enabled,
    int? episodes,
    int? fromMinute,
    int? untilMinute,
  }) {
    return StillWatchingSettings(
      enabled: enabled ?? this.enabled,
      episodes: episodes ?? this.episodes,
      fromMinute: fromMinute ?? this.fromMinute,
      untilMinute: untilMinute ?? this.untilMinute,
    );
  }

  /// Ce que le serveur en dit, ou null s'il est trop ancien pour connaître le
  /// réglage : l'appareil garde alors le sien au lieu de le voir remis aux
  /// valeurs par défaut à chaque synchronisation.
  static StillWatchingSettings? fromJson(Map<String, dynamic> json) {
    final enabled = json['still_watching_enabled'];
    if (enabled is! bool) return null;
    return StillWatchingSettings(
      enabled: enabled,
      episodes: (json['still_watching_episodes'] as num?)?.toInt() ?? 3,
      fromMinute:
          (json['still_watching_from'] as num?)?.toInt() ?? allDayMinute,
      untilMinute:
          (json['still_watching_until'] as num?)?.toInt() ?? allDayMinute,
    ).normalized();
  }

  /// Les champs envoyés au serveur. Toujours les quatre : les deux bornes ne
  /// se valident qu'ensemble.
  Map<String, Object> toJson() => {
        'still_watching_enabled': enabled,
        'still_watching_episodes': episodes,
        'still_watching_from': allDay ? allDayMinute : fromMinute,
        'still_watching_until': allDay ? allDayMinute : untilMinute,
      };

  /// Ramène une valeur lue du disque ou du réseau dans ce que le lecteur sait
  /// appliquer, plutôt que de se fier à qui l'a écrite.
  StillWatchingSettings normalized() {
    final validHours = fromMinute >= 0 &&
        fromMinute < 24 * 60 &&
        untilMinute >= 0 &&
        untilMinute < 24 * 60 &&
        fromMinute != untilMinute;
    return StillWatchingSettings(
      enabled: enabled,
      episodes: episodes.clamp(1, maxEpisodes),
      fromMinute: validHours ? fromMinute : allDayMinute,
      untilMinute: validHours ? untilMinute : allDayMinute,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StillWatchingSettings &&
      other.enabled == enabled &&
      other.episodes == episodes &&
      other.fromMinute == fromMinute &&
      other.untilMinute == untilMinute;

  @override
  int get hashCode => Object.hash(enabled, episodes, fromMinute, untilMinute);
}
