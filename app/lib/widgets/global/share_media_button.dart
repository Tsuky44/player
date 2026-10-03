import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import 'share_media_dialog.dart';
import '../../theme/app_icons.dart';

/// Le bouton « Partager par lien » d'un film ou d'un épisode (ADR-0037).
///
/// Absent pour un compte sans le droit `share_media` : ce qui n'est pas
/// dessiné ne produit pas de 403. Le serveur reste le seul garde. Absent
/// aussi sur un téléviseur, qui n'a personne à qui coller le lien copié.
class ShareMediaButton extends StatelessWidget {
  const ShareMediaButton({
    super.key,
    required this.item,
    this.title,
    this.compact = false,
  });

  final HomeMediaItem item;

  /// Le nom montré dans la boîte de dialogue ; celui du média par défaut.
  /// Un épisode le complète du nom de sa série.
  final String? title;

  /// Version réduite pour une ligne de liste.
  final bool compact;

  bool get _isShareable =>
      item.isAvailable &&
      (item.media.type == MediaType.movie ||
          item.media.type == MediaType.episode);

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (TvMode.isTv || !auth.permissions.shareMedia || !_isShareable) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: 'Partager par lien',
      onPressed: () => showShareMediaDialog(
        context,
        api: auth.apiClient,
        mediaId: item.media.id,
        title: title ?? item.media.title,
      ),
      iconSize: compact ? 20 : 22,
      visualDensity: compact ? VisualDensity.compact : null,
      color: AppColors.textSecondary,
      icon: const Icon(AppIcons.link),
    );
  }
}

/// Le bouton « Partager par lien » d'une saison ou d'une série entière : un
/// seul lien, dont le visiteur choisit les épisodes (ADR-0037 §8).
///
/// Mêmes absences que [ShareMediaButton], plus une : sans épisode lisible, le
/// serveur refuserait le lien.
class ShareCollectionButton extends StatelessWidget {
  const ShareCollectionButton({
    super.key,
    required this.mediaId,
    required this.title,
    required this.tooltip,
    required this.hasPlayableEpisode,
    this.compact = false,
  });

  /// L'id de la saison ou de la série.
  final int mediaId;

  /// Le nom montré dans la boîte de dialogue : « Lioness », « Lioness ·
  /// Saison 2 ».
  final String title;
  final String tooltip;
  final bool hasPlayableEpisode;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (TvMode.isTv ||
        !auth.permissions.shareMedia ||
        !hasPlayableEpisode ||
        mediaId <= 0) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: () => showShareMediaDialog(
        context,
        api: auth.apiClient,
        mediaId: mediaId,
        title: title,
        collection: true,
      ),
      iconSize: compact ? 20 : 22,
      visualDensity: compact ? VisualDensity.compact : null,
      color: AppColors.textSecondary,
      icon: const Icon(AppIcons.link),
    );
  }
}
