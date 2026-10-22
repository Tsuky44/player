import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/profile_avatar.dart';
import '../../models/server_account.dart';
import '../../services/api_client.dart';
import '../../services/avatar_photo_cache.dart';
import '../../theme/app_colors.dart';
import '../../theme/profile_avatars.dart';

/// La pastille d'une personne : sa photo, son avatar de la galerie, ou son
/// initiale sur sa teinte. La même partout — « Qui regarde ? », le menu du
/// compte, le choix de l'image —, pour qu'on se reconnaisse d'un écran à
/// l'autre (ADR-0078).
class ProfileDisc extends StatelessWidget {
  const ProfileDisc({
    super.key,
    required this.account,
    required this.size,
    this.avatar,
  });

  final ServerAccount account;
  final double size;

  /// Remplace l'image retenue au carnet : l'aperçu d'un choix pas encore
  /// envoyé.
  final ProfileAvatar? avatar;

  /// Les coins suivent la taille : un carré arrondi plutôt qu'un rond, comme
  /// les affiches de l'app.
  static BorderRadius radiusFor(double size) =>
      BorderRadius.circular(size * 0.2);

  @override
  Widget build(BuildContext context) {
    final shown = avatar ?? ProfileAvatar.parse(account.avatar);
    return ClipRRect(
      borderRadius: radiusFor(size),
      child: SizedBox.square(
        dimension: size,
        child: switch (shown) {
          PresetAvatar(:final key) => _preset(ProfileAvatars.byKey(key)),
          PhotoAvatar(:final version) => _PhotoDisc(
              account: account,
              version: version,
              fallback: _initial(),
            ),
          InitialAvatar() => _initial(),
        },
      ),
    );
  }

  Widget _preset(AvatarPreset? preset) {
    if (preset == null) return _initial();
    return PresetArtwork(preset: preset, size: size);
  }

  Widget _initial() {
    final name = account.username;
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return ColoredBox(
      color: tintFor(account),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      ),
    );
  }

  /// Une teinte stable par compte : la même personne garde sa couleur d'un
  /// lancement à l'autre, quel que soit l'ordre du carnet.
  static Color tintFor(ServerAccount account) {
    final seed = account.id.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
    return AppColors.profileTints[seed % AppColors.profileTints.length];
  }
}

/// Le dessin d'un avatar de la galerie, à n'importe quelle taille.
class PresetArtwork extends StatelessWidget {
  const PresetArtwork({super.key, required this.preset, required this.size});

  final AvatarPreset preset;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [preset.from, preset.to],
        ),
      ),
      child: Center(
        child: Icon(
          preset.icon,
          size: size * 0.52,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _PhotoDisc extends StatelessWidget {
  const _PhotoDisc({
    required this.account,
    required this.version,
    required this.fallback,
  });

  final ServerAccount account;
  final String version;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    return FutureBuilder(
      future: AvatarPhotoCache.photoFor(account, version, api.fetchAvatarPhoto),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        // Pendant la lecture, ou sans réseau : l'initiale, jamais un trou.
        if (bytes == null) return fallback;
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}
