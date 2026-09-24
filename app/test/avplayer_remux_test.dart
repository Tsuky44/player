import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/playback/avplayer_remux.dart';

/// AVPlayer ne lit que ce que le serveur **recopie**. Ce qui demanderait un
/// ré-encodage reste sur mpv en Direct Play : économiser la batterie du client
/// ne doit jamais faire travailler le serveur.
void main() {
  MediaTracks tracks({
    String codec = 'hevc',
    int bitDepth = 10,
    String hdr = '',
    List<MediaSubtitleTrack> subtitles = const [],
  }) =>
      MediaTracks(
        video: MediaVideoTrack(
          codec: codec,
          width: 3840,
          height: 2160,
          hdrFormat: hdr,
          bitDepth: bitDepth,
        ),
        audio: [MediaAudioTrack(index: 1, typedIndex: 0, codec: 'truehd')],
        subtitles: subtitles,
      );

  test('un HEVC 10 bits HDR10 part sur AVPlayer', () {
    expect(AvPlayerRemux.refusal(tracks(hdr: 'hdr10')), isNull);
  });

  test('le H.264 aussi, quel que soit le nom que ffprobe lui donne', () {
    expect(AvPlayerRemux.refusal(tracks(codec: 'h264', bitDepth: 8)), isNull);
    expect(AvPlayerRemux.refusal(tracks(codec: 'avc1', bitDepth: 8)), isNull);
  });

  test('l’audio ne décide rien : le serveur convertit TrueHD et DTS', () {
    // La piste de [tracks] est en TrueHD.
    expect(AvPlayerRemux.refusal(tracks()), isNull);
  });

  test('ce qu’AVPlayer ne décode pas reste sur mpv', () {
    for (final codec in ['vp9', 'av1', 'mpeg2video', 'vc1', 'mpeg4']) {
      expect(AvPlayerRemux.refusal(tracks(codec: codec)), isNotNull,
          reason: codec);
    }
  });

  test('un 12 bits reste sur mpv', () {
    expect(AvPlayerRemux.refusal(tracks(bitDepth: 12)), isNotNull);
  });

  test('le Dolby Vision reste sur mpv, faute de pouvoir lire un profil 5', () {
    expect(AvPlayerRemux.refusal(tracks(hdr: 'dolbyvision')), isNotNull);
  });

  test('des sous-titres image choisis à l’ouverture restent sur mpv', () {
    final withPgs = tracks(subtitles: [
      MediaSubtitleTrack(lang: 'fr', name: 'Français', image: true),
      MediaSubtitleTrack(lang: 'en', name: 'English'),
    ]);
    expect(AvPlayerRemux.refusal(withPgs, subtitleLang: 'fr'), isNotNull);
    expect(AvPlayerRemux.refusal(withPgs, subtitleLang: 'en'), isNull);
    expect(AvPlayerRemux.refusal(withPgs), isNull);
  });

  test('sans piste vidéo connue, mpv', () {
    expect(
      AvPlayerRemux.refusal(MediaTracks(audio: const [], subtitles: const [])),
      isNotNull,
    );
  });
}
