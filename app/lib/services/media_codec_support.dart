/// Ce que le moteur de lecture de cette plateforme sait décoder.
///
/// Seul le web a une réponse à donner ici : un navigateur est le seul moteur
/// du projet dont les codecs varient d'une installation à l'autre — Safari
/// décode le HEVC et pas Firefox, l'AV1 dépend de la version. Ailleurs, mpv et
/// ExoPlayer répondent chacun par leurs propres moyens, et ce fichier n'a rien
/// à dire.
library;

export 'media_codec_support_io.dart'
    if (dart.library.js_interop) 'media_codec_support_web.dart';
