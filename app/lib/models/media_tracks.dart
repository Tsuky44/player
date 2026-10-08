import '../l10n/tr.dart';
import 'media_subtitle_track.dart';

/// Maps an ISO 639 language code (2 or 3 letters) to a readable French name.
/// Falls back to the upper-cased code, or "Indéterminé" when unknown/empty.
String languageName(String? code) {
  if (code == null) return tr('Indéterminé');
  final c = code.trim().toLowerCase();
  if (c.isEmpty || c == 'und') return tr('Indéterminé');
  const map = {
    'fre': 'Français', 'fra': 'Français', 'fr': 'Français',
    'eng': 'Anglais', 'en': 'Anglais',
    'spa': 'Espagnol', 'es': 'Espagnol',
    'ger': 'Allemand', 'deu': 'Allemand', 'de': 'Allemand',
    'ita': 'Italien', 'it': 'Italien',
    'por': 'Portugais', 'pt': 'Portugais',
    'jpn': 'Japonais', 'ja': 'Japonais',
    'kor': 'Coréen', 'ko': 'Coréen',
    'chi': 'Chinois', 'zho': 'Chinois', 'zh': 'Chinois',
    'rus': 'Russe', 'ru': 'Russe',
    'ara': 'Arabe', 'ar': 'Arabe',
    'nld': 'Néerlandais', 'dut': 'Néerlandais', 'nl': 'Néerlandais',
    'pol': 'Polonais', 'pl': 'Polonais',
    'tur': 'Turc', 'tr': 'Turc',
    'hin': 'Hindi', 'hi': 'Hindi',
    'swe': 'Suédois', 'sv': 'Suédois',
    'nor': 'Norvégien', 'no': 'Norvégien',
    'dan': 'Danois', 'da': 'Danois',
    'fin': 'Finnois', 'fi': 'Finnois',
    'ces': 'Tchèque', 'cze': 'Tchèque', 'cs': 'Tchèque',
    'ukr': 'Ukrainien', 'uk': 'Ukrainien',
    'heb': 'Hébreu', 'he': 'Hébreu',
    'tha': 'Thaï', 'th': 'Thaï',
    'vie': 'Vietnamien', 'vi': 'Vietnamien',
  };
  final name = map[c];
  return name == null ? code.toUpperCase() : tr(name);
}

String? _channelsLabel(int channels) {
  switch (channels) {
    case 1:
      return 'Mono';
    case 2:
      return tr('Stéréo');
    case 6:
      return '5.1';
    case 8:
      return '7.1';
    default:
      return channels > 0 ? '${channels}ch' : null;
  }
}

/// Audio track metadata as probed from the original media file.
///
/// [typedIndex] is the position among audio streams only (FFmpeg "0:a:N") and
/// is the stable identifier used everywhere — for HLS rendition mapping and for
/// matching against the player's enumerated audio tracks in Direct Play.
class MediaAudioTrack {
  final int index;
  final int typedIndex;
  final String codec;
  final String? language;
  final String? title;
  final int channels;
  final bool isDefault;

  /// `atmos` or `dtsx`, empty for plain channel-based audio.
  ///
  /// Object-based audio is not a codec: Atmos rides inside E-AC-3 (as JOC) or
  /// TrueHD, and DTS:X inside DTS. The server reads it off the stream profile,
  /// which is the only place it is visible — so a track can say "EAC3" and be
  /// Atmos, and nothing but this field can tell them apart.
  final String spatialFormat;

  /// Whether the track is a bit-exact copy of its master (TrueHD, FLAC,
  /// DTS-HD MA, PCM).
  final bool lossless;

  MediaAudioTrack({
    required this.index,
    required this.typedIndex,
    required this.codec,
    this.language,
    this.title,
    this.channels = 0,
    this.isDefault = false,
    this.spatialFormat = '',
    this.lossless = false,
  });

  factory MediaAudioTrack.fromJson(Map<String, dynamic> json) {
    return MediaAudioTrack(
      index: json['index'] as int? ?? 0,
      typedIndex: json['typed_index'] as int? ?? 0,
      codec: json['codec_name'] as String? ?? '',
      language: json['language'] as String?,
      title: json['title'] as String?,
      channels: json['channels'] as int? ?? 0,
      isDefault: json['default'] as bool? ?? false,
      spatialFormat: json['spatial_format'] as String? ?? '',
      lossless: json['lossless'] as bool? ?? false,
    );
  }

  /// How the format is named to a person: "Dolby Atmos", "DTS:X", "Dolby
  /// Digital Plus", "DTS-HD MA".
  ///
  /// The spatial format wins when there is one, because it is what the track
  /// actually is — "EAC3" on an Atmos track is true and useless.
  String get formatLabel {
    switch (spatialFormat) {
      case 'atmos':
        return tr('Dolby Atmos');
      case 'dtsx':
        return 'DTS:X';
    }
    switch (codec.toLowerCase()) {
      case 'eac3':
        return tr('Dolby Digital+');
      case 'ac3':
        return tr('Dolby Digital');
      case 'truehd':
        return tr('Dolby TrueHD');
      case 'dts':
        return lossless ? 'DTS-HD MA' : 'DTS';
      case 'aac':
        return 'AAC';
      case 'flac':
        return 'FLAC';
      case 'opus':
        return 'Opus';
      default:
        return codec.toUpperCase();
    }
  }

  /// Readable name, e.g. "Français (Dolby Atmos 5.1)".
  ///
  /// Le titre de piste que porte le fichier répète souvent la langue et les
  /// canaux (« Français 5.1 ») : ce qu'il redit n'est pas écrit une seconde
  /// fois, sans quoi on lisait « Français (Français 5.1 5.1) ».
  String get displayName {
    final lang = languageName(language);
    var t = title?.trim() ?? '';
    if (t.toLowerCase().startsWith(lang.toLowerCase())) {
      t = t.substring(lang.length).trim();
    }
    final lowerTitle = t.toLowerCase();
    final parts = <String>[];
    if (t.isNotEmpty) parts.add(t);
    if (codec.isNotEmpty &&
        !lowerTitle.contains(formatLabel.toLowerCase())) {
      parts.add(formatLabel);
    }
    final ch = _channelsLabel(channels);
    if (ch != null && !lowerTitle.contains(ch)) parts.add(ch);
    return parts.isEmpty ? lang : '$lang (${parts.join(' ')})';
  }
}

/// Primary video stream metadata (codec, pixel dimensions, dynamic range).
class MediaVideoTrack {
  final String codec;
  final int width;
  final int height;

  /// `hdr10`, `hlg`, `hdr10plus`, `dolbyvision`, or empty for SDR.
  ///
  /// Decided server-side rather than reconstructed here: what makes a stream
  /// HDR is a rule about colour transfer and side data, and a rule stated in
  /// two languages is a rule that will eventually disagree with itself.
  final String hdrFormat;

  /// Bits per sample, resolved by the server (8 when nothing said so).
  final int bitDepth;

  MediaVideoTrack({
    required this.codec,
    required this.width,
    required this.height,
    this.hdrFormat = '',
    this.bitDepth = 8,
  });

  factory MediaVideoTrack.fromJson(Map<String, dynamic> json) {
    return MediaVideoTrack(
      codec: json['codec_name'] as String? ?? '',
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      hdrFormat: json['hdr_format'] as String? ?? '',
      bitDepth: json['bit_depth'] as int? ?? 8,
    );
  }

  /// Resolution label, e.g. "4K", "1080p", "720p".
  String get resolutionLabel {
    // Cinemascope files often omit the black bars: width preserves the tier.
    if (width >= 7680 || height >= 4320) return '8K';
    if (width >= 3840 || height >= 2000) return '4K';
    if (width >= 1920 && height <= 1080 && height > 0) return '1080p';
    if (width >= 1280 && height <= 720 && height > 0) return '720p';
    if (height <= 0) return '';
    return '${height}p';
  }

  String get codecLabel {
    switch (codec.toLowerCase()) {
      case 'h264':
        return 'H.264';
      case 'hevc':
      case 'h265':
        return tr('HEVC (H.265)');
      default:
        return codec.toUpperCase();
    }
  }

  /// True for anything that needs an HDR display to look right.
  bool get isHDR => hdrFormat.isNotEmpty;

  /// How the dynamic range is named to a person, or empty for SDR.
  String get hdrLabel {
    switch (hdrFormat) {
      case 'dolbyvision':
        return tr('Dolby Vision');
      case 'hdr10plus':
        return 'HDR10+';
      case 'hdr10':
        return 'HDR10';
      case 'hlg':
        return 'HLG';
      default:
        return '';
    }
  }

  /// e.g. "4K HEVC Dolby Vision".
  String get displayName {
    final parts = <String>[
      if (resolutionLabel.isNotEmpty) resolutionLabel,
      if (codec.isNotEmpty) codec.toUpperCase(),
      if (hdrLabel.isNotEmpty) hdrLabel,
    ];
    return parts.join(' ');
  }
}

/// Un barreau de l'échelle de transcodage, tel que le serveur l'annonce.
///
/// Le débit voyage avec le barreau parce que c'est contre lui que le choix se
/// fait : une lecture qui se coupe est une lecture qui demande plus que la ligne
/// ne porte, et « descendre d'un cran » doit vouloir dire « demander moins »,
/// pas « perdre des lignes ». Un menu qui n'affiche que des résolutions oblige à
/// deviner.
class QualityTier {
  /// Ce que le client renvoie en `?quality=`. Stable, y compris entre versions.
  final String key;

  /// L'entrée de menu, débit compris, p. ex. « 1080p · 6 Mbit/s ».
  final String label;

  /// La taille d'image du barreau.
  final int width;
  final int height;

  /// Vidéo plus audio : ce que la ligne doit réellement porter.
  final int bitrateBps;

  const QualityTier({
    required this.key,
    required this.label,
    required this.height,
    required this.bitrateBps,
    this.width = 0,
  });

  /// « 1080p » — la moitié gauche du libellé serveur.
  String get resolutionLabel => _labelParts.$1;

  /// « 6 Mbit/s » — la moitié droite, ou null si le serveur n'en a pas mis.
  String? get bitrateLabel => _labelParts.$2;

  /// « 1920×1080 · 6 Mbit/s », pour les menus qui décrivent le barreau.
  String get sizeAndBitrateLabel {
    final size = (width > 0 && height > 0) ? '$width×$height' : null;
    final parts = [if (size != null) size, if (bitrateLabel != null) bitrateLabel!];
    return parts.isEmpty ? label : parts.join(' · ');
  }

  /// Le serveur compose le libellé entier pour qu'un débit ne soit écrit qu'à
  /// un seul endroit : un client qui reformaterait le nombre pourrait finir par
  /// annoncer autre chose que ce qui est encodé. Le séparateur fait partie de
  /// ce contrat, et un libellé sans séparateur s'affiche tel quel.
  (String, String?) get _labelParts {
    final parts = label.split(' · ');
    if (parts.length < 2) return (label, null);
    return (parts.first, parts.sublist(1).join(' · '));
  }

  factory QualityTier.fromJson(Map<String, dynamic> json) {
    return QualityTier(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      bitrateBps: json['bitrate_bps'] as int? ?? 0,
    );
  }
}

/// Combined video/audio/subtitle tracks returned by the tracks API.
class MediaTracks {
  final MediaVideoTrack? video;
  final List<MediaAudioTrack> audio;
  final List<MediaSubtitleTrack> subtitles;

  /// L'échelle de transcodage que ce serveur propose pour ce fichier, du plus
  /// exigeant au moins exigeant.
  ///
  /// Vide quand le serveur est plus ancien que l'échelle — le menu retombe alors
  /// sur sa liste figée. La médiathèque peut être servie par plusieurs serveurs
  /// (voir ADR-0013), donc « le serveur est à jour » ne se suppose jamais.
  final List<QualityTier> qualities;

  /// Ce que le fichier demande à la ligne en Direct Play, en bits par
  /// seconde ; 0 quand le serveur ne le sait pas ou ne l'annonce pas. La
  /// qualité automatique s'en sert pour choisir un barreau (ADR-0056).
  final int sourceBitrateBps;

  MediaTracks({
    this.video,
    required this.audio,
    required this.subtitles,
    this.qualities = const [],
    this.sourceBitrateBps = 0,
  });

  factory MediaTracks.fromJson(Map<String, dynamic> json) {
    return MediaTracks(
      video: json['video'] is Map<String, dynamic>
          ? MediaVideoTrack.fromJson(json['video'] as Map<String, dynamic>)
          : null,
      audio: (json['audio'] as List<dynamic>?)
              ?.map((e) => MediaAudioTrack.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      subtitles: (json['subtitles'] as List<dynamic>?)
              ?.map((e) => MediaSubtitleTrack.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      sourceBitrateBps: (json['source_bitrate_bps'] as num?)?.toInt() ?? 0,
      qualities: (json['qualities'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(QualityTier.fromJson)
              .where((tier) => tier.key.isNotEmpty && tier.label.isNotEmpty)
              .toList() ??
          const [],
    );
  }
}
