import '../../models/models.dart';
import '../../models/series_track_preferences.dart';
import '../../services/playback_preferences_storage.dart';
import 'playback/carried_subtitle.dart';

/// Audio/subtitle choices carried over to another episode: the next one in
/// the same sitting, or any episode of the series later on (ADR-0044).
class PlayerPlaybackPreferences {
  /// Position of the chosen track in the media it was chosen in, or -1 when
  /// the choice comes from the series memory, which only knows a language.
  final int audioIndex;

  /// Language of the chosen audio track, when the previous media knew it.
  ///
  /// This is what finds the track again in the next episode — see
  /// [audioIndexIn]. It is also the same choice expressed in a form mpv can
  /// act on *before* the file is loaded, so the right track is picked at load
  /// time instead of being switched to a second later, mid-sentence.
  final String? audioLang;

  /// Le sous-titre à retrouver dans le média suivant. Voir [CarriedSubtitle].
  final CarriedSubtitle? subtitle;

  /// Id mpv de la piste choisie : ne vaut que dans le média d'où il vient, donc
  /// seulement en dernier recours, quand [subtitle] ne peut rien désigner.
  final String? internalSubId;

  /// True when the previous episode had no active subtitles.
  final bool subtitlesOff;

  const PlayerPlaybackPreferences({
    required this.audioIndex,
    this.audioLang,
    this.subtitle,
    this.internalSubId,
    required this.subtitlesOff,
  });

  /// Ce que le compte a retenu pour la série, sous la forme que le lecteur
  /// sait déjà appliquer à un épisode.
  factory PlayerPlaybackPreferences.fromSeries(SeriesTrackPreferences series) {
    final choice = series.subtitle;
    final subtitle = choice == null || choice.off
        ? null
        : CarriedSubtitle.fromSeries(choice);
    return PlayerPlaybackPreferences(
      audioIndex: -1,
      audioLang: series.audioLang,
      subtitle: subtitle,
      subtitlesOff: subtitle == null,
    );
  }

  /// La piste de [tracks] qui tient le choix audio.
  ///
  /// La langue passe avant le rang : d'un épisode à l'autre l'ordre des pistes
  /// change, et le même rang désignait alors une autre langue. Le rang ne sert
  /// plus qu'à départager deux pistes de la langue voulue. Quand l'épisode n'a
  /// pas cette langue, c'est [defaultLang] — le réglage du compte — puis la
  /// piste par défaut du fichier.
  int audioIndexIn(List<MediaAudioTrack> tracks, {String? defaultLang}) {
    if (tracks.isEmpty) return audioIndex < 0 ? 0 : audioIndex;
    final lang = audioLang;
    if (lang == null) {
      if (audioIndex >= 0) return audioIndex.clamp(0, tracks.length - 1);
      return PlaybackPreferencesStorage.pickAudioIndex(tracks, defaultLang);
    }
    bool speaks(MediaAudioTrack track) =>
        PlaybackPreferencesStorage.normalizeLangCode(track.language) == lang;
    if (audioIndex >= 0 &&
        audioIndex < tracks.length &&
        speaks(tracks[audioIndex])) {
      return audioIndex;
    }
    return PlaybackPreferencesStorage.pickAudioIndex(
        tracks, tracks.any(speaks) ? lang : defaultLang);
  }
}
