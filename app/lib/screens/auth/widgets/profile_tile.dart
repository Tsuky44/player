import 'package:flutter/material.dart';

import '../../../models/server_account.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../tv/tv_focus.dart';
import '../../../widgets/global/profile_disc.dart';
import '../../../l10n/tr.dart';

/// Une personne de « Qui regarde ? ».
///
/// Au survol de la souris, un crayon apparaît sur sa pastille, comme sur
/// Netflix : il ouvre le choix de l'image. En mode « Gérer les profils » — le
/// chemin du tactile et de la télécommande —, le crayon est sur toutes les
/// pastilles et un appui modifie au lieu d'ouvrir la session. À la
/// télécommande, la touche menu y mène aussi.
class ProfileTile extends StatefulWidget {
  const ProfileTile({
    super.key,
    required this.account,
    required this.size,
    required this.current,
    required this.editing,
    required this.autofocus,
    required this.enabled,
    required this.onSelect,
    required this.onEdit,
  });

  final ServerAccount account;
  final double size;
  final bool current;
  final bool editing;
  final bool autofocus;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback onEdit;

  @override
  State<ProfileTile> createState() => _ProfileTileState();
}

class _ProfileTileState extends State<ProfileTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final name = widget.account.username;
    final editing = widget.editing;
    final action = editing ? widget.onEdit : widget.onSelect;
    final radius = ProfileDisc.radiusFor(widget.size);
    final showPencil = editing || _hovered;

    return ProfileTileFrame(
      size: widget.size,
      caption: name,
      note: widget.current ? tr('En cours') : null,
      child: Semantics(
        button: true,
        label: editing
            ? tr('Changer l’image de {0}', [name])
            : tr('Regarder en tant que {0}', [name]),
        onTap: widget.enabled ? action : null,
        excludeSemantics: true,
        child: TvFocusable(
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          onSelect: action,
          onContextMenu: widget.onEdit,
          borderRadius: radius,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Stack(
              children: [
                Material(
                  color: Colors.transparent,
                  borderRadius: radius,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.enabled ? action : null,
                    child: Container(
                      foregroundDecoration: widget.current && !editing
                          ? BoxDecoration(
                              borderRadius: radius,
                              border: Border.all(
                                  color: AppColors.textPrimary, width: 2),
                            )
                          : null,
                      child: ProfileDisc(
                        account: widget.account,
                        size: widget.size,
                      ),
                    ),
                  ),
                ),
                // En mode gestion, un voile dit que l'appui modifie.
                if (editing)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.glassFillStrong,
                          borderRadius: radius,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: AnimatedOpacity(
                    opacity: showPencil ? 1 : 0,
                    duration: AppMotion.fade(context, AppMotion.micro),
                    curve: AppMotion.curve,
                    child: _PencilButton(
                      // Invisible, il ne doit pas non plus capter un clic.
                      onPressed:
                          showPencil && widget.enabled ? widget.onEdit : null,
                      tooltip: tr('Changer l’image de {0}', [name]),
                    ),
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

class _PencilButton extends StatelessWidget {
  const _PencilButton({required this.onPressed, required this.tooltip});

  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: ExcludeFocus(
        // Au D-pad, c'est la touche menu ou « Gérer les profils » qui mènent
        // au choix : un second arrêt du focus par pastille ralentirait tout.
        child: Material(
          color: AppColors.background.withValues(alpha: 0.72),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: const Padding(
              padding: EdgeInsets.all(7),
              child: Icon(
                AppIcons.edit,
                size: 16,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// « Ajouter » : la même forme, un « + » à la place du visage.
class AddProfileTile extends StatelessWidget {
  const AddProfileTile({
    super.key,
    required this.size,
    required this.enabled,
    required this.onSelect,
  });

  final double size;
  final bool enabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final radius = ProfileDisc.radiusFor(size);
    return ProfileTileFrame(
      size: size,
      caption: tr('Ajouter'),
      child: Semantics(
        button: true,
        label: tr('Ajouter un utilisateur'),
        onTap: enabled ? onSelect : null,
        excludeSemantics: true,
        child: TvFocusable(
          enabled: enabled,
          onSelect: onSelect,
          borderRadius: radius,
          child: Material(
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: const BorderSide(color: AppColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onSelect : null,
              child: SizedBox.square(
                dimension: size,
                child: Icon(
                  AppIcons.add,
                  size: size * 0.34,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La pastille et son nom dessous, à largeur fixe pour que la grille reste
/// alignée quelle que soit la longueur des noms.
class ProfileTileFrame extends StatelessWidget {
  const ProfileTileFrame({
    super.key,
    required this.size,
    required this.caption,
    required this.child,
    this.note,
  });

  final double size;
  final String caption;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 10),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: AppType.callout,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (note != null)
            Text(
              note!,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: AppType.footnote,
              ),
            ),
        ],
      ),
    );
  }
}
