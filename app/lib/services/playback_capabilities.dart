import 'package:flutter/foundation.dart';
import 'package:onyx_player_android/onyx_player_android.dart';

import '../utils/app_platform.dart';
import 'media_codec_support.dart';

/// Ce que cet appareil sait décoder et restituer, dit au serveur.
///
/// Le serveur décidait jusqu'ici pour un client imaginaire : un navigateur qui
/// lit du H.264 8 bits et de l'AAC stéréo, et rien d'autre. Ce client existe,
/// mais c'est le **plus faible** — mpv sur un ordinateur décode à peu près
/// tout, ExoPlayer sur un téléviseur transmet du Dolby Digital Plus à un ampli
/// sans y toucher — et tous deux recevaient une version ré-encodée, repliée en
/// stéréo et aplatie en SDR d'un fichier qu'ils savaient lire tel quel.
///
/// Alors le client le dit, et le serveur fait le moins de dégâts compatible
/// avec ce qu'il a entendu. Ne rien dire reste valide : le serveur retombe
/// alors sur son ancien comportement, ce qui est exactement ce qu'il faut pour
/// une version installée qui n'a pas encore ce fichier.
@immutable
class PlaybackCapabilities {
  const PlaybackCapabilities({
    required this.container,
    required this.videoCodecs,
    required this.audioCodecs,
    required this.maxAudioChannels,
    required this.maxVideoBitDepth,
    required this.hdr,
    required this.dolbyVision,
    required this.label,
    this.missingDirectPlayAudio = const {},
  });

  /// `fmp4` ou `ts`. Le format de segment décide autant que le décodeur : le
  /// MPEG-TS n'a pas de type de flux pour le VP9, l'AV1, le FLAC ou l'Opus, et
  /// c'est le seul format qui transporte les métadonnées HDR d'une copie.
  final String container;

  /// Noms canoniques : `h264`, `hevc`, `av1`, `vp9`.
  final Set<String> videoCodecs;

  /// Noms canoniques : `aac`, `ac3`, `eac3`, `flac`, `opus`, `alac`, `dts`…
  final Set<String> audioCodecs;

  /// Ce que la **sortie** peut porter, pas ce que le décodeur sait lire. C'est
  /// le nombre qui décide si une piste 5.1 survit au trajet.
  final int maxAudioChannels;

  /// 8 pour un navigateur, 10 dès qu'un décodeur matériel moderne est là.
  final int maxVideoBitDepth;

  /// Un écran qu'on peut piloter en PQ ou en HLG. Sans ça, le serveur applique
  /// un tone mapping plutôt que d'envoyer une image délavée.
  final bool hdr;

  /// Un décodeur qui comprend la couche de métadonnées RPU, ce qui n'est pas la
  /// même chose qu'un écran HDR. Un seul profil en a réellement besoin — le
  /// profil 5, dont la couche de base est dans un espace colorimétrique privé.
  final bool dolbyVision;

  /// De quoi lire la ligne de log au démarrage d'une lecture.
  final String label;

  /// Les codecs audio que le moteur **local** ne sait pas décoder quand il lit
  /// le fichier lui-même (Direct Play).
  ///
  /// Ce n'est pas l'inverse de [audioCodecs], qui dit ce que le serveur peut
  /// envoyer dans un segment : mpv lit le DTS sans que le fMP4 sache le porter.
  ///
  /// Vide partout aujourd'hui — mpv embarque un FFmpeg complet (voir les
  /// paquets `media_kit_libs_*` sous packages/) et ExoPlayer le décodeur FFmpeg
  /// de NextLib. Reste le filet pour ce qu'aucun des deux ne décode : une telle
  /// piste ne produit pas d'erreur, l'image défile sans son, et le seul remède
  /// est de laisser le serveur la décoder — donc de passer en HLS.
  final Set<String> missingDirectPlayAudio;

  /// Si le moteur local sait décoder [codec] (nom ffprobe) en Direct Play.
  bool decodesInDirectPlay(String codec) {
    final name = canonicalAudioCodec(codec);
    return name == null || !missingDirectPlayAudio.contains(name);
  }

  /// Ce que le serveur suppose quand le client ne dit rien.
  static const legacy = PlaybackCapabilities(
    container: 'ts',
    videoCodecs: {'h264'},
    audioCodecs: {'aac'},
    maxAudioChannels: 2,
    maxVideoBitDepth: 8,
    hdr: false,
    dolbyVision: false,
    label: 'legacy',
  );

  /// mpv : ordinateurs de bureau et iOS.
  ///
  /// mpv porte ses propres décodeurs — il n'y a pas d'appareil à interroger, et
  /// la liste ne dépend ni du système ni du matériel. Ce qui reste incertain
  /// est en aval : la sortie audio et l'écran.
  ///
  /// `maxAudioChannels` est déclaré au maximum bien que mpv sorte souvent en
  /// stéréo (son défaut `auto-safe` suit ce que le périphérique annonce). Ce
  /// n'est pas une perte : quand la sortie est stéréo, c'est mpv qui replie,
  /// avec les niveaux de l'ADR-0005 — donc le même résultat qu'un repli
  /// serveur, sans le ré-encodage. Et quand elle ne l'est pas, le surround
  /// arrive.
  ///
  /// `hdr` est vrai pour la même raison : mpv sait toujours quoi faire d'une
  /// source HDR, soit en la transmettant, soit en la tone-mappant lui-même sur
  /// le GPU. Les deux valent mieux qu'un ré-encodage serveur. `dolbyVision`
  /// reste faux : le rendu par l'API `libmpv` de media_kit ne traite pas la
  /// couche RPU, donc un profil 5 y sortirait vert.
  static const mpv = PlaybackCapabilities(
    container: 'fmp4',
    videoCodecs: {'h264', 'hevc', 'av1', 'vp9'},
    audioCodecs: {'aac', 'ac3', 'eac3', 'flac', 'opus', 'alac'},
    maxAudioChannels: 8,
    maxVideoBitDepth: 12,
    hdr: true,
    dolbyVision: false,
    label: 'mpv',
  );

  /// Ce qu'ExoPlayer a mesuré sur cet appareil.
  ///
  /// Tout vient du natif : les décodeurs de `MediaCodecList`, les canaux et le
  /// passthrough des `AudioCapabilities` — c'est-à-dire de l'ampli branché — et
  /// les formats HDR de l'écran. Un téléviseur et le téléphone qui le pilote ne
  /// produisent donc pas les mêmes capacités, ce qui est le but.
  factory PlaybackCapabilities.fromDevice(OnyxDeviceCapabilities device) {
    final video = <String>{'h264'};
    for (final mime in device.videoMimeTypes) {
      final name = _canonicalFromMime(mime, _videoMimeNames);
      if (name != null) video.add(name);
    }

    // L'AAC est décodé partout ; l'(E-)AC-3 l'est aussi, en logiciel, par le
    // décodeur FFmpeg d'ExoPlayer quand la puce n'en a pas — le serveur peut
    // donc le recopier plutôt que le ré-encoder. TrueHD et DTS sont décodés de
    // la même façon mais n'ont pas de place dans un segment fMP4.
    final audio = <String>{'aac', ..._ffmpegDecodedAudio};
    // Ce que la puce décode…
    for (final mime in device.audioMimeTypes) {
      final name = _canonicalFromMime(mime, _audioMimeNames);
      if (name != null) audio.add(name);
    }
    // …et ce que la sortie transmet sans décoder. Le second ensemble n'est pas
    // inclus dans le premier : un boîtier peut faire traverser du Dolby Digital
    // Plus jusqu'à l'ampli sans avoir de décodeur pour lui. C'est ce chemin-là,
    // et lui seul, qui laisse arriver l'Atmos intact.
    for (final mime in device.passthroughAudioMimeTypes) {
      final name = _canonicalFromMime(mime, _audioMimeNames);
      if (name != null) audio.add(name);
    }

    final hdr = device.hdrFormats.isNotEmpty;
    return PlaybackCapabilities(
      container: 'fmp4',
      videoCodecs: video,
      audioCodecs: audio,
      maxAudioChannels: device.maxAudioChannels.clamp(2, 8).toInt(),
      maxVideoBitDepth: device.maxVideoBitDepth.clamp(8, 12).toInt(),
      hdr: hdr,
      dolbyVision: device.hdrFormats.contains('dolbyvision'),
      // Ce que ni MediaCodec, ni le passthrough, ni le FFmpeg de NextLib ne
      // décode — l'AC-4, en pratique. Ne rien supposer d'un codec inconnu
      // garde le Direct Play qui marchait déjà.
      missingDirectPlayAudio: _needsDeviceSupport.difference(audio),
      label: 'exoplayer '
          '(${device.maxAudioChannels}ch, '
          '${device.maxVideoBitDepth}bit, '
          'hdr=${hdr ? device.hdrFormats.join('+') : 'non'}, '
          'passthrough=${device.passthroughAudioMimeTypes.isEmpty ? 'non' : device.passthroughAudioMimeTypes.length})',
    );
  }

  /// Ce que ce navigateur-ci a répondu à `MediaSource.isTypeSupported`.
  ///
  /// Rien n'est supposé : la table des codecs d'un navigateur dépend de sa
  /// version et du système en dessous. Un navigateur qui ne répond rien du tout
  /// retombe sur [legacy], qui est ce qui marchait déjà.
  factory PlaybackCapabilities.browser() {
    final video = supportedMseVideoCodecs();
    final audio = supportedMseAudioCodecs();
    if (video.isEmpty) return legacy;

    return PlaybackCapabilities(
      container: 'fmp4',
      videoCodecs: {'h264', ...video},
      audioCodecs: {'aac', ...audio},
      // Un onglet n'a pas de sortie multicanal exploitable : le navigateur
      // replie tout sur le périphérique par défaut, et le fait moins bien que
      // le serveur — qui, lui, remonte le canal central.
      maxAudioChannels: 2,
      // Le 10 bits ne dépend pas que du décodeur : la surface de composition
      // d'un navigateur reste en 8 bits. Demander du Main 10 y donne une image
      // noire, sans erreur.
      maxVideoBitDepth: 8,
      hdr: false,
      dolbyVision: false,
      label: 'navigateur (${video.join('+')})',
    );
  }

  /// Les paramètres à ajouter à `/start`.
  ///
  /// Les noms sont ceux que `ParseCapabilities` lit côté serveur. Chacun est
  /// facultatif de son côté, donc en oublier un dégrade cet axe-là et rien
  /// d'autre.
  Map<String, String> toQueryParameters() => {
        'container': container,
        'vcodec': videoCodecs.join(','),
        'acodec': audioCodecs.join(','),
        'channels': '$maxAudioChannels',
        'bitdepth': '$maxVideoBitDepth',
        'hdr': hdr ? '1' : '0',
        'dv': dolbyVision ? '1' : '0',
      };

  @override
  String toString() => 'PlaybackCapabilities($label, $container, '
      'v=${videoCodecs.join('+')}, a=${audioCodecs.join('+')}, '
      '${maxAudioChannels}ch, ${maxVideoBitDepth}bit, hdr=$hdr, dv=$dolbyVision)';
}

/// Les types MIME Android, ramenés aux noms que le serveur compare.
const _videoMimeNames = <String, String>{
  'video/avc': 'h264',
  'video/hevc': 'hevc',
  'video/x-vnd.on2.vp9': 'vp9',
  'video/av01': 'av1',
  'video/dolby-vision': 'hevc',
};

const _audioMimeNames = <String, String>{
  'audio/mp4a-latm': 'aac',
  'audio/ac3': 'ac3',
  'audio/eac3': 'eac3',
  'audio/eac3-joc': 'eac3',
  'audio/ac4': 'ac4',
  'audio/vnd.dts': 'dts',
  'audio/vnd.dts.hd': 'dts',
  'audio/true-hd': 'truehd',
  'audio/flac': 'flac',
  'audio/opus': 'opus',
  'audio/alac': 'alac',
  'audio/mpeg': 'mp3',
};

String? _canonicalFromMime(String mime, Map<String, String> table) =>
    table[mime.toLowerCase().trim()];

/// Les formats qu'ExoPlayer ne lit qu'avec de l'aide : un décodeur MediaCodec,
/// un passthrough HDMI, ou le décodeur FFmpeg de NextLib.
const _needsDeviceSupport = <String>{'truehd', 'dts', 'ac3', 'eac3', 'ac4'};

/// Ce que le FFmpeg de NextLib décode quel que soit l'appareil (sa build active
/// `ac3`, `eac3`, `dca`, `mlp` et `truehd`). L'AC-4 n'y est pas.
const _ffmpegDecodedAudio = <String>{'truehd', 'dts', 'ac3', 'eac3'};

/// Le nom canonique d'un codec audio tel que ffprobe l'écrit, ou null pour un
/// codec dont cette table ne dit rien.
@visibleForTesting
String? canonicalAudioCodec(String codec) {
  switch (codec.toLowerCase().trim()) {
    case 'truehd':
    case 'mlp':
      return 'truehd';
    case 'dts':
    case 'dca':
      return 'dts';
    case 'eac3':
      return 'eac3';
    case 'ac3':
      return 'ac3';
    case 'ac4':
      return 'ac4';
    default:
      return null;
  }
}

/// Résout les capacités de cet appareil, une fois par processus.
abstract final class PlaybackCapabilitiesResolver {
  static PlaybackCapabilities? _current;

  /// Ce qui a été résolu. Avant [initialize] — et sur toute plateforme qui ne
  /// répond jamais — c'est [PlaybackCapabilities.legacy], donc le comportement
  /// que le serveur avait avant que ce fichier existe.
  static PlaybackCapabilities get current =>
      _current ?? PlaybackCapabilities.legacy;

  /// Demande à la plateforme ce qu'elle sait faire. Appelable plusieurs fois ;
  /// seul le premier appel travaille.
  static Future<void> initialize() async {
    if (_current != null) return;

    if (AppPlatform.isWeb) {
      _current = PlaybackCapabilities.browser();
    } else if (AppPlatform.isAndroid) {
      try {
        _current = PlaybackCapabilities.fromDevice(
          await OnyxPlayer.deviceCapabilities(),
        );
      } catch (error) {
        // Une version de l'hôte plus ancienne que ce contrat, ou une puce qui
        // refuse de s'énumérer. Se rabattre sur le transcodage marche toujours.
        debugPrint('PlaybackCapabilities: interrogation impossible ($error)');
        _current = PlaybackCapabilities.legacy;
      }
    } else {
      _current = PlaybackCapabilities.mpv;
    }

    debugPrint('PlaybackCapabilities: ${_current!}');
  }

  @visibleForTesting
  static void overrideWith(PlaybackCapabilities? capabilities) =>
      _current = capabilities;
}
