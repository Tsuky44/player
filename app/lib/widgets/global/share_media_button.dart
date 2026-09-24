import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import 'share_media_dialog.dart';

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
      icon: const Icon(Icons.link_rounded),
    );
  }
}
