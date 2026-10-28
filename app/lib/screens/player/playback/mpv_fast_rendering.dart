import '../playback_profile.dart';

/// Les options mpv du dessin au plus simple, pour un appareil en mode léger
/// (ADR-0086). Vide pour un profil qui ne le demande pas.
///
/// Le fichier est toujours lu tel quel, en Direct Play : rien ici ne
/// demande au serveur de faire le travail. Ce qui change, c'est ce que la
/// machine dépense pour mettre chaque image décodée à l'écran.
///
/// - La mise à l'échelle par défaut (`lanczos`, `ewa_lanczossharp` pour
///   l'agrandissement) passe plusieurs fois sur chaque pixel ; ramener du 4K
///   vers un écran 1080p coûte alors plus au processeur graphique d'une
///   petite machine que le décodage lui-même. Le bilinéaire est une passe.
/// - Debanding, tramage et sigmoïde sont des passes de plus sur l'image
///   entière, invisibles à trois mètres d'un téléviseur.
/// - `vd-lavc-fast` et `vd-lavc-skiploopfilter=nonref` laissent au décodeur
///   logiciel (quand le matériel ne prend pas le codec) ses raccourcis : le
///   filtre de boucle sauté sur les images que rien ne référence ne se voit
///   pas, et il pèse jusqu'au quart du temps de décodage.
/// - `framedrop=decoder+vo` : une image en retard est lâchée plutôt que de
///   ralentir toute la lecture. Le son reste calé, l'image rattrape.
Map<String, String> mpvFastRenderingOptions(PlaybackProfile profile) {
  if (!profile.fastRendering) return const {};
  return const {
    'scale': 'bilinear',
    'dscale': 'bilinear',
    'cscale': 'bilinear',
    'correct-downscaling': 'no',
    'linear-downscaling': 'no',
    'sigmoid-upscaling': 'no',
    'deband': 'no',
    'dither-depth': 'no',
    'hdr-compute-peak': 'no',
    'vd-lavc-fast': 'yes',
    'vd-lavc-skiploopfilter': 'nonref',
    'framedrop': 'decoder+vo',
  };
}

/// Pose [mpvFastRenderingOptions] par [set].
Future<void> applyMpvFastRendering(
  PlaybackProfile profile,
  Future<void> Function(String name, String value) set,
) async {
  for (final option in mpvFastRenderingOptions(profile).entries) {
    await set(option.key, option.value);
  }
}
