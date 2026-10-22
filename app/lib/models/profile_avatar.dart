/// L'image de profil d'un compte, lue dans ce que le serveur en dit
/// (`User.avatar`) : rien (l'initiale), un avatar de la galerie de l'app, ou
/// une photo envoyée. Voir ADR-0078.
sealed class ProfileAvatar {
  const ProfileAvatar();

  static const _presetPrefix = 'preset:';
  static const _photoPrefix = 'photo:';

  /// Une valeur inconnue — un serveur plus récent qui saurait autre chose —
  /// retombe sur l'initiale plutôt que sur une image cassée.
  factory ProfileAvatar.parse(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.startsWith(_presetPrefix) &&
        value.length > _presetPrefix.length) {
      return PresetAvatar(value.substring(_presetPrefix.length));
    }
    if (value.startsWith(_photoPrefix) && value.length > _photoPrefix.length) {
      return PhotoAvatar(value.substring(_photoPrefix.length));
    }
    return const InitialAvatar();
  }
}

/// Pas d'image : la pastille porte l'initiale.
class InitialAvatar extends ProfileAvatar {
  const InitialAvatar();
}

/// Un avatar dessiné par l'app, désigné par sa clé.
class PresetAvatar extends ProfileAvatar {
  const PresetAvatar(this.key);
  final String key;
}

/// Une photo gardée par le serveur. [version] change à chaque envoi : c'est
/// elle qui périme ce que l'app a déjà en mémoire.
class PhotoAvatar extends ProfileAvatar {
  const PhotoAvatar(this.version);
  final String version;
}
