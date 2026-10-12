part of 'use_player_controller.dart';

/// La langue qu'on suit, quand un épisode ne l'a pas (ADR-0057) : ce qu'il
/// manque à l'épisode qu'on lance ou au suivant, et ce qu'on répond à la
/// question « continuer ou attendre ? ».
extension PlayerControllerLanguage on PlayerController {
  /// Ce qui manquerait à un épisode dont les langues audio sont [nextLangs]
  /// pour enchaîner sans rien demander, ou null s'il a ce qu'il faut.
  AudioLanguageGap? audioLanguageGapWith(List<String> nextLangs) =>
      AudioLanguageGap.between(
        heard: _selectedAudioLang,
        wanted: _carriedAudioLang,
        next: nextLangs,
      );

  /// Ce qui manque à l'épisode qu'on vient de lancer, ou null s'il n'y a rien
  /// à demander. À lire une fois la liste des pistes arrivée.
  ///
  /// La langue suivie est celle retenue pour la série, sinon la langue audio
  /// par défaut du compte. Qui a déjà répondu « continuer » pour cette saison
  /// n'est pas réinterrogé à chaque épisode ; lire un épisode qui a la langue
  /// suivie efface cette réponse, pour que le prochain épisode en retard
  /// repose la question.
  Future<AudioLanguageGap?> launchLanguageGap() async {
    final memory = _seriesMemory;
    final audio = mediaTracks?.audio;
    if (memory == null || audio == null) return null;
    final wanted = _carriedAudioLang ?? await _loadDefaultAudioLang();
    final available = <String>[
      for (final track in audio)
        if (PlaybackPreferencesStorage.normalizeLangCode(track.language)
            case final String code)
          code,
    ];
    final gap = AudioLanguageGap.missing(
      wanted: wanted,
      heard: _selectedAudioLang,
      available: available,
    );
    if (gap == null) {
      if (wanted != null && available.contains(wanted)) {
        await memory.acceptOtherLanguage(null);
      }
      return null;
    }
    return await memory.acceptedWithout(gap.wanted) ? null : gap;
  }

  /// « Continuer » : la série cesse d'attendre [lang], et la question ne
  /// revient pas tant qu'on ne l'a pas réentendue.
  Future<void> continueWithoutAudioLanguage(String lang) async {
    final memory = _seriesMemory;
    if (memory == null) return;
    await memory.acceptOtherLanguage(lang);
    await memory.rememberAwaitedAudio('');
  }

  /// « Attendre » : le compte retient qu'il attend [lang] pour cette série.
  /// Rend la main une fois le serveur prévenu, ou le choix noté pour plus tard.
  Future<void> awaitAudioLanguage(String lang) async {
    final memory = _seriesMemory;
    if (memory == null) return;
    await memory.acceptOtherLanguage(null);
    await memory.rememberAwaitedAudio(lang);
  }
}
