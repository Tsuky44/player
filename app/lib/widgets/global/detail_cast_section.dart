import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_focus.dart';
import '../../tv/tv_focus_memory.dart';
import '../../utils/poster_url.dart';
import '../../utils/responsive.dart';
import 'app_network_image.dart';
import 'detail_metadata.dart';

/// La rangée « Casting » de toutes les fiches, en portraits ronds. Toucher une
/// personne ouvre sa page via [onTapMember].
class CastSection extends StatelessWidget {
  final List<CastMember> cast;
  final void Function(CastMember member)? onTapMember;

  /// Marge gauche/droite du titre et du bord de défilement. Par défaut la
  /// marge de page — sauf quand la section est déjà nichée dans une colonne
  /// qui la pose elle-même (ex. à côté de la fiche TMDB), où elle vaut 0.
  final double? horizontalPadding;

  const CastSection({
    super.key,
    required this.cast,
    this.onTapMember,
    this.horizontalPadding,
  });

  /// Le diamètre d'un portrait, qui est aussi sa largeur de décodage.
  static const double avatarSize = 70;
  static const double _cardWidth = 90;
  static const double _rowHeight = 124;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) return const SizedBox.shrink();
    final pad = horizontalPadding ?? AppLayout.pagePadding(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 8, pad, 16),
          child: Text(tr('Casting'), style: detailSectionTitleStyle(context)),
        ),
        // La rangée se souvient de la personne sur laquelle la télécommande
        // était — voir [TvFocusMemory].
        TvFocusMemory(
          child: SizedBox(
            height: _rowHeight,
            child: ListView.separated(
              scrollCacheExtent: AppLayout.imageCacheExtent(context),
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: pad),
              itemCount: cast.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) => _CastCard(
                member: cast[index],
                onTap: onTapMember == null
                    ? null
                    : () => onTapMember!(cast[index]),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CastCard extends StatelessWidget {
  final CastMember member;
  final VoidCallback? onTap;

  const _CastCard({required this.member, this.onTap});

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      // A cast card with no destination is decoration; the remote skips it.
      enabled: onTap != null,
      onSelect: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: CastSection._cardWidth,
        child: MouseRegion(
          cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            onTap: onTap,
            child: Column(
              children: [
                ClipOval(
                  child: AppNetworkImage(
                    // The catalog serves h632 portraits — ~6x the pixels a card
                    // this size can show, fetched a dozen at a time.
                    url: castProfileUrl(member.profileUrl),
                    width: CastSection.avatarSize,
                    height: CastSection.avatarSize,
                    fit: BoxFit.cover,
                    errorWidget: const _CastPlaceholder(),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppType.footnote,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (member.character != null && member.character!.isNotEmpty)
                  Text(
                    member.character!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppType.caption,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CastPlaceholder extends StatelessWidget {
  const _CastPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceElevated,
      alignment: Alignment.center,
      child: const Icon(AppIcons.person, size: 32, color: AppColors.textMuted),
    );
  }
}
