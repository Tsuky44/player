/// Hors du web, personne n'interroge `MediaSource` : mpv porte ses propres
/// décodeurs et ExoPlayer interroge MediaCodec côté natif.
library;

/// Toujours vide. L'appelant se rabat sur ce qu'il sait de son moteur.
Set<String> supportedMseVideoCodecs() => const {};

/// Toujours vide, pour la même raison.
Set<String> supportedMseAudioCodecs() => const {};
