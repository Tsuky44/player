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
        video: ['video/avc', 'video/hevc', 'video/av01'],
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
}
