import 'package:flutter_test/flutter_test.dart';
import 'package:onyx_player_android/onyx_player_android.dart';
import 'package:onyx/services/playback_capabilities.dart';

/// Ce qui est protégé ici n'est pas une conversion mais une asymétrie de
/// risque : déclarer moins que ce que l'appareil sait faire coûte du CPU
/// serveur, déclarer plus coûte le film — un flux qu'un client ne décode pas ne
/// produit pas d'erreur, il produit une image noire sur un son qui joue.
void main() {
  group('capacités par défaut', () {
    test('le repli est ce que le serveur supposait déjà', () {
      const caps = PlaybackCapabilities.legacy;
      final params = caps.toQueryParameters();

      expect(params['container'], 'ts');
      expect(params['vcodec'], 'h264');
      expect(params['acodec'], 'aac');
      expect(params['channels'], '2');
      expect(params['bitdepth'], '8');
      expect(params['hdr'], '0');
    });

    test('mpv déclare large, mais pas le Dolby Vision', () {
      const caps = PlaybackCapabilities.mpv;
      expect(caps.videoCodecs, containsAll(['h264', 'hevc', 'av1', 'vp9']));
      expect(caps.audioCodecs, containsAll(['aac', 'ac3', 'eac3', 'flac']));
      expect(caps.maxAudioChannels, 8);
      expect(caps.hdr, isTrue);
      // Le rendu par l'API libmpv ne traite pas la couche RPU : un profil 5 y
      // sortirait vert, donc le serveur doit continuer à le tone-mapper.
      expect(caps.dolbyVision, isFalse);
    });

    test('mpv dans une vue native (gpu-next) déclare le Dolby Vision', () {
      // libplacebo applique la couche RPU : un profil 5 peut être recopié.
      const caps = PlaybackCapabilities.mpvGpuNext;
      expect(caps.dolbyVision, isTrue);
      expect(caps.hdr, isTrue);
      expect(caps.videoCodecs, PlaybackCapabilities.mpv.videoCodecs);
      expect(caps.audioCodecs, PlaybackCapabilities.mpv.audioCodecs);
    });
  });

  group('capacités mesurées sur l\'appareil', () {
    OnyxDeviceCapabilities device({
      List<String> video = const ['video/avc'],
      List<String> audio = const ['audio/mp4a-latm'],
      List<String> passthrough = const [],
      int channels = 2,
      List<String> hdr = const [],
      int bitDepth = 8,
    }) =>
        OnyxDeviceCapabilities(
          videoMimeTypes: video,
          audioMimeTypes: audio,
          passthroughAudioMimeTypes: passthrough,
          maxAudioChannels: channels,
          hdrFormats: hdr,
          maxVideoBitDepth: bitDepth,
        );

    test('un téléphone nu reste stéréo et SDR', () {
      final caps = PlaybackCapabilities.fromDevice(device(
        video: ['video/avc', 'video/hevc'],
        audio: ['audio/mp4a-latm', 'audio/ac3'],
      ));

      expect(caps.videoCodecs, containsAll(['h264', 'hevc']));
      expect(caps.maxAudioChannels, 2);
      expect(caps.hdr, isFalse);
      expect(caps.dolbyVision, isFalse);
    });

    test('un téléviseur relié à un ampli garde le surround et le passthrough',
        () {
      final caps = PlaybackCapabilities.fromDevice(device(
        video: ['video/avc', 'video/hevc', 'video/av01', 'video/dolby-vision'],
        audio: ['audio/mp4a-latm'],
        // Le boîtier n'a pas de décodeur E-AC-3 mais sait le faire traverser :
        // c'est le seul chemin par lequel l'Atmos arrive intact, et il doit
        // donc élargir les codecs déclarés autant qu'un vrai décodeur.
        passthrough: ['audio/eac3-joc', 'audio/eac3', 'audio/ac3'],
        channels: 8,
        hdr: ['hdr10', 'dolbyvision'],
        bitDepth: 10,
      ));

      expect(caps.audioCodecs, contains('eac3'));
      expect(caps.audioCodecs, contains('ac3'));
      expect(caps.maxAudioChannels, 8);
      expect(caps.maxVideoBitDepth, 10);
      expect(caps.hdr, isTrue);
      expect(caps.dolbyVision, isTrue);
      expect(caps.container, 'fmp4');
    });

    test('un écran Dolby Vision sans puce qui le décode reste hors DV', () {
      // C'est l'écran qui déclare la compatibilité — un boîtier relié en
      // HDMI à un téléviseur Dolby Vision sans avoir lui-même la puce qui
      // comprend la couche RPU. Le serveur doit tone-mapper, pas recopier.
      final caps = PlaybackCapabilities.fromDevice(device(
        video: ['video/avc', 'video/hevc'],
        hdr: ['hdr10', 'dolbyvision'],
        bitDepth: 10,
      ));

      expect(caps.hdr, isTrue);
      expect(caps.dolbyVision, isFalse);
    });

    test('les codecs de repli sont toujours déclarés', () {
      // Une puce qui refuse de s'énumérer répond une liste vide. Le serveur
      // n'encode que du H.264 et de l'AAC : les omettre ne laisserait aucun
      // chemin légal pour un fichier qu'il faut ré-encoder.
      final caps = PlaybackCapabilities.fromDevice(
        device(video: const [], audio: const []),
      );
      expect(caps.videoCodecs, contains('h264'));
      expect(caps.audioCodecs, contains('aac'));
    });

    test('les valeurs aberrantes sont ramenées dans les bornes', () {
      final caps = PlaybackCapabilities.fromDevice(
        device(channels: 64, bitDepth: 2),
      );
      expect(caps.maxAudioChannels, 8);
      expect(caps.maxVideoBitDepth, 8);
    });
  });

  group('pistes muettes en Direct Play', () {
    // Une piste que le moteur local ne décode pas n'échoue pas : elle est
    // listée, sélectionnée, et silencieuse. C'est ce qui arrivait au TrueHD
    // Atmos 7.1 sur mac, Windows et Android.
    test('mpv (FFmpeg complet) garde toutes les pistes en Direct Play', () {
      const caps = PlaybackCapabilities.mpv;
      for (final codec in [
        'truehd',
        'mlp',
        'eac3',
        'ac3',
        'dts',
        'aac',
        'flac',
        'opus',
      ]) {
        expect(caps.decodesInDirectPlay(codec), isTrue, reason: codec);
      }
    });

    test('ExoPlayer sans décodeur ni passthrough décode via FFmpeg', () {
      final caps = PlaybackCapabilities.fromDevice(OnyxDeviceCapabilities(
        videoMimeTypes: ['video/avc'],
        audioMimeTypes: ['audio/mp4a-latm', 'audio/ac3'],
        passthroughAudioMimeTypes: [],
        maxAudioChannels: 2,
        hdrFormats: [],
        maxVideoBitDepth: 8,
      ));
      for (final codec in ['truehd', 'dts', 'eac3', 'ac3']) {
        expect(caps.decodesInDirectPlay(codec), isTrue, reason: codec);
      }
      // Le seul format que rien ne décode sur cet appareil.
      expect(caps.decodesInDirectPlay('ac4'), isFalse);
      // L'(E-)AC-3 décodé en logiciel peut aussi être recopié par le serveur.
      expect(caps.audioCodecs, containsAll(['ac3', 'eac3']));
      // Ce que la table ne connaît pas reste en Direct Play, comme avant.
      expect(caps.decodesInDirectPlay('pcm_s24le'), isTrue);
      expect(caps.decodesInDirectPlay('vorbis'), isTrue);
    });

    test('un passthrough TrueHD vers un ampli garde le Direct Play', () {
      final caps = PlaybackCapabilities.fromDevice(OnyxDeviceCapabilities(
        videoMimeTypes: ['video/avc'],
        audioMimeTypes: ['audio/mp4a-latm'],
        passthroughAudioMimeTypes: ['audio/true-hd', 'audio/eac3-joc'],
        maxAudioChannels: 8,
        hdrFormats: [],
        maxVideoBitDepth: 10,
      ));
      expect(caps.decodesInDirectPlay('truehd'), isTrue);
      expect(caps.decodesInDirectPlay('eac3'), isTrue);
    });

    test('le repli legacy ne change rien au Direct Play', () {
      expect(PlaybackCapabilities.legacy.decodesInDirectPlay('truehd'), isTrue);
    });
  });

  test('les paramètres portent les noms que le serveur lit', () {
    // Les clés sont le contrat avec `streaming.ParseCapabilities`. Un nom qui
    // dérive ne casse rien de visible : le serveur retombe simplement sur son
    // client le plus faible, et tout redevient silencieusement du H.264 stéréo.
    final params = PlaybackCapabilities.mpv.toQueryParameters();
    expect(
      params.keys.toSet(),
      {'container', 'vcodec', 'acodec', 'channels', 'bitdepth', 'hdr', 'dv'},
    );
  });

  group('AVPlayer en recopie (ADR-0035)', () {
    // Sans `remux`, un remux 4K au-dessus du plafond de débit du serveur était
    // ré-encodé en H.264 : un cœur occupé pour une image moins bonne, sur un
    // appareil qui aurait tiré ce débit de toute façon en Direct Play.
    test('iPhone et Mac demandent la recopie au-delà du plafond de débit', () {
      expect(PlaybackCapabilities.avPlayer.toQueryParameters()['remux'], '1');
    });

    test('l’Apple TV aussi, qui ne lit jamais le fichier lui-même', () {
      expect(PlaybackCapabilities.appleTv.toQueryParameters()['remux'], '1');
    });

    test('mpv lit le fichier : ses sessions restent sous le plafond', () {
      expect(
        PlaybackCapabilities.mpv.toQueryParameters().containsKey('remux'),
        isFalse,
      );
    });

    test('la vue native garde le HDR, pas le Dolby Vision', () {
      // Un profil 5 étiqueté `hvc1` sortirait vert dans AVPlayer.
      const caps = PlaybackCapabilities.avPlayer;
      expect(caps.hdr, isTrue);
      expect(caps.dolbyVision, isFalse);
      expect(caps.videoCodecs, {'h264', 'hevc'});
    });
  });
}
