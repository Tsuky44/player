import 'models.dart' show languageName;

/// An external subtitle language offered by the server (sidecar file or
/// OpenSubtitles download), addressed by its ISO-639 [lang] code.
///
/// MKV-embedded subtitle extraction has been abandoned: subtitles are always
/// clean external .vtt files served by the backend and injected into the player
/// as external tracks.
class MediaSubtitleTrack {
  final String lang;
  final String name;
  // True when a local file already exists (no download needed). When false the
  // server will fetch it on first request, which may take a moment.
  final bool ready;

  /// True while the server has only extracted the beginning of this track. It is
  /// usable immediately, but the complete version is still being produced and
  /// will need re-attaching once it lands.
  final bool partial;

  /// Position among the file's subtitle streams (the N in ffmpeg's 0:s:N), or
  /// -1 when unknown. This is what pairs an embedded track seen in Direct Play
  /// with its canonical entry here, so the client never has to derive a language
  /// code itself.
  final int typedIndex;

  /// True for a track that only subtitles foreign dialogue rather than the whole
  /// film. A file commonly ships both a full and a forced track for the same
  /// language, and picking the forced one by mistake looks like broken subtitles.
  final bool forced;

  /// True when the container flags this track as its preferred one.
  final bool isDefault;

  /// True for a bitmap track (PGS/VOBSUB). It has no .vtt: Direct Play renders it
  /// natively, while transcoding has to paint it into the picture — which makes
  /// it the one subtitle choice that costs a new HLS session.
  final bool image;

  /// Code de langue du flux (`fr`), tel que le serveur l'a normalisé, sans le
  /// rang que porte [lang] (`fr2`) ni l'espace des pistes image (`img3`). Vide
  /// quand le serveur ne le donne pas : voir [baseLanguage].
  final String language;

  MediaSubtitleTrack({
    required this.lang,
    required this.name,
    this.ready = false,
    this.partial = false,
    this.typedIndex = -1,
    this.forced = false,
    this.isDefault = false,
    this.image = false,
    this.language = '',
  });

  factory MediaSubtitleTrack.fromJson(Map<String, dynamic> json) {
    final lang = (json['lang'] as String?) ?? '';
    final name = (json['name'] as String?) ?? '';
    return MediaSubtitleTrack(
      lang: lang,
      name: name.isNotEmpty ? name : languageName(lang),
      ready: json['ready'] as bool? ?? false,
      partial: json['partial'] as bool? ?? false,
      typedIndex: (json['typed_index'] as num?)?.toInt() ?? -1,
      forced: json['forced'] as bool? ?? false,
      isDefault: json['default'] as bool? ?? false,
      image: json['image'] as bool? ?? false,
      language: json['language'] as String? ?? '',
    );
  }

  String get displayName => name.isNotEmpty ? name : languageName(lang);

  /// La langue qui désigne cette piste d'un média à l'autre. Les clés sont
  /// attribuées fichier par fichier (`fr2` peut être la piste forcée ici et la
  /// complète ailleurs), la langue, elle, ne bouge pas. Un serveur qui ne la
  /// donne pas encore : on la retire de la clé d'une piste texte ; celle d'une
  /// piste image (`img3`) ne dit rien de sa langue.
  String get baseLanguage {
    if (language.isNotEmpty) return language;
    if (image) return '';
    return lang.replaceAll(RegExp(r'\d+$'), '');
  }
}
