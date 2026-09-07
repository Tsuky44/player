import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';

/// Les libellés que voit l'utilisateur, et la seule chose qu'ils doivent faire :
/// nommer ce que la piste **est**, pas le codec qui la transporte. « EAC3 » sur
/// une piste Atmos est exact et inutile.
void main() {
  group('piste vidéo', () {
    test('le format HDR vient du serveur et se lit tel quel', () {
      final track = MediaVideoTrack.fromJson({
        'codec_name': 'hevc',
        'width': 3840,
        'height': 2160,
        'hdr_format': 'dolbyvision',
        'bit_depth': 10,
      });
      expect(track.resolutionLabel, '4K');
      expect(track.isHDR, isTrue);
      expect(track.displayName, '4K HEVC Dolby Vision');
    });

    test('une source SDR ne gagne pas de badge', () {
      final track = MediaVideoTrack.fromJson({
        'codec_name': 'h264',
        'width': 1920,
        'height': 1080,
      });
      expect(track.isHDR, isFalse);
      expect(track.hdrLabel, '');
      expect(track.displayName, '1080p H264');
    });

    test('chaque format HDR a son nom', () {
      for (final entry in {
        'hdr10': 'HDR10',
        'hdr10plus': 'HDR10+',
        'hlg': 'HLG',
        'dolbyvision': 'Dolby Vision',
        '': '',
      }.entries) {
        final track = MediaVideoTrack(
          codec: 'hevc',
          width: 3840,
          height: 2160,
          hdrFormat: entry.key,
        );
        expect(track.hdrLabel, entry.value, reason: entry.key);
      }
    });

    test('une réponse de serveur ancienne reste lisible', () {
      // Pas de hdr_format, pas de bit_depth : le média se décrit comme avant.
      final track = MediaVideoTrack.fromJson({
        'codec_name': 'hevc',
        'width': 3840,
        'height': 2160,
      });
      expect(track.isHDR, isFalse);
      expect(track.bitDepth, 8);
      expect(track.displayName, '4K HEVC');
    });
  });

  group('piste audio', () {
    test('l\'Atmos est nommé, pas le flux qui le porte', () {
      final track = MediaAudioTrack.fromJson({
        'codec_name': 'eac3',
        'channels': 6,
        'language': 'fre',
        'spatial_format': 'atmos',
      });
      expect(track.formatLabel, 'Dolby Atmos');
      expect(track.displayName, contains('Dolby Atmos'));
      expect(track.displayName, contains('5.1'));
    });

    test('le même codec sans Atmos garde son propre nom', () {
      final track = MediaAudioTrack.fromJson({
        'codec_name': 'eac3',
        'channels': 6,
        'language': 'eng',
      });
      expect(track.formatLabel, 'Dolby Digital+');
    });

    test('le DTS sans perte se distingue du DTS ordinaire', () {
      final lossy = MediaAudioTrack.fromJson({
        'codec_name': 'dts',
        'channels': 6,
      });
      final lossless = MediaAudioTrack.fromJson({
        'codec_name': 'dts',
        'channels': 8,
        'lossless': true,
      });
      final dtsx = MediaAudioTrack.fromJson({
        'codec_name': 'dts',
        'channels': 8,
        'lossless': true,
        'spatial_format': 'dtsx',
      });
      expect(lossy.formatLabel, 'DTS');
      expect(lossless.formatLabel, 'DTS-HD MA');
      expect(dtsx.formatLabel, 'DTS:X');
    });
  });
}
