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

/// Les pistes audio qu'un fichier ouvert tel quel par l'élément `<video>` peut
/// porter, au-delà de ce que dit `MediaSource` — la question d'un téléviseur
/// LG, qui lit le fichier par son propre pipeline (ADR-0076).
///
/// `canPlayType` et non `isTypeSupported` : ce pipeline-là n'est pas celui des
/// segments, et le DTS en est l'exemple — LG l'a retiré de ses modèles 2020 à
/// 2022 puis rétabli, et seul l'élément sait lequel est branché.
const _fileAudioProbes = <String, String>{
  'ac3': 'audio/mp4; codecs="ac-3"',
  'eac3': 'audio/mp4; codecs="ec-3"',
  'ac4': 'audio/mp4; codecs="ac-4"',
  'dts': 'audio/mp4; codecs="dtsc"',
  'truehd': 'audio/mp4; codecs="mlpa"',
};

Set<String> supportedFileAudioCodecs() {
  final out = <String>{};
  final probe = web.HTMLVideoElement();
  for (final entry in _fileAudioProbes.entries) {
    // « maybe » et « probably » valent oui : la chaîne vide est le seul non.
    if (probe.canPlayType(entry.value).isNotEmpty) out.add(entry.key);
  }
  return out;
}

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
