/// Ce que ce navigateur-ci sait décoder, demandé à `MediaSource`.
///
/// C'est la seule réponse fiable : la table des codecs d'un navigateur dépend
/// de sa version, du système en dessous et parfois du matériel. Safari décode
/// le HEVC, Firefox non ; l'AV1 est arrivé à des dates différentes partout. Un
/// codec supposé et absent ne produit pas d'erreur — les segments s'empilent,
/// le son joue, et l'image n'arrive jamais.
library;

import 'package:web/web.dart' as web;

/// Les chaînes soumises à `isTypeSupported`, par nom de codec canonique.
///
/// Chacune est un profil réel et courant plutôt qu'un nom de famille : la
/// question posée à un navigateur est toujours « ce profil précis », et une
/// chaîne sans profil reçoit des réponses incohérentes d'un moteur à l'autre.
const _videoProbes = <String, String>{
  // Baseline/Main/High 8 bits : le socle, décodé partout.
  'h264': 'video/mp4; codecs="avc1.640028"',
  // HEVC Main 10, profil de la quasi-totalité des masters 4K.
  'hevc': 'video/mp4; codecs="hvc1.2.4.L153.B0"',
  'av1': 'video/mp4; codecs="av01.0.08M.10"',
  'vp9': 'video/mp4; codecs="vp09.00.10.08"',
};

const _audioProbes = <String, String>{
  'aac': 'audio/mp4; codecs="mp4a.40.2"',
  'ac3': 'audio/mp4; codecs="ac-3"',
  'eac3': 'audio/mp4; codecs="ec-3"',
  'opus': 'audio/mp4; codecs="opus"',
  'flac': 'audio/mp4; codecs="flac"',
};

Set<String> supportedMseVideoCodecs() => _supported(_videoProbes);

Set<String> supportedMseAudioCodecs() => _supported(_audioProbes);

Set<String> _supported(Map<String, String> probes) {
  final out = <String>{};
  for (final entry in probes.entries) {
    try {
      if (web.MediaSource.isTypeSupported(entry.value)) {
        out.add(entry.key);
      }
    } catch (_) {
      // Un navigateur sans Media Source Extensions du tout. Il ne lira rien de
      // ce lecteur de toute façon, et l'appelant a un repli.
    }
  }
  return out;
}
