import 'still_watching_settings.dart';

/// Les réglages de lecture d'un compte, tels que le serveur les tient
/// (ADR-0043).
class AccountPlaybackPreferences {
  final bool autoSkipIntro;

  /// Code ISO à deux lettres, ou null pour la piste par défaut du fichier.
  final String? defaultAudioLang;

  /// Null quand le serveur est trop ancien pour connaître ce réglage.
  final StillWatchingSettings? stillWatching;

  /// Faux tant que le compte n'a rien enregistré : ses valeurs ne sont alors
  /// que des défauts, et le premier appareil peut y déposer les siennes.
  final bool isSaved;

  const AccountPlaybackPreferences({
    required this.autoSkipIntro,
    required this.defaultAudioLang,
    this.stillWatching,
    required this.isSaved,
  });

  factory AccountPlaybackPreferences.fromJson(Map<String, dynamic> json) {
    final lang = (json['default_audio_lang'] as String?)?.trim() ?? '';
    final updatedAt = (json['updated_at'] as String?) ?? '';
    return AccountPlaybackPreferences(
      autoSkipIntro: json['auto_skip_intro'] == true,
      defaultAudioLang: lang.isEmpty ? null : lang,
      stillWatching: StillWatchingSettings.fromJson(json),
      isSaved: updatedAt.isNotEmpty,
    );
  }
}
