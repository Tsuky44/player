import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../utils/poster_url.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/global/app_network_image.dart';
import 'request_status_motion.dart';

/// Le fond de la fiche, bord à bord comme sur OnyxHub (`MediaBackdrop`) :
/// l'image en pleine qualité à 80 %, un léger vignettage, un voile à gauche
/// derrière le titre et un fondu en haut et en bas qui rejoint la page.
///
/// Les voiles sont des dégradés, pas des flous : ils se dessinent une fois et
/// ne coûtent rien au défilement.
class RequestDetailBackdrop extends StatelessWidget {
  const RequestDetailBackdrop({super.key, required this.backdropUrl});

  final String? backdropUrl;

  /// Part de la hauteur d'écran couverte par le fond (70 % en téléphone,
  /// 88 % au-delà, comme OnyxHub).
  static double heightFor(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return height * (AppLayout.isCompact(context) ? 0.7 : 0.88);
  }

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    const page = AppColors.background;
    return SizedBox(
      height: heightFor(context),
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: 0.8,
            child: AppNetworkImage(
              url: detailBackdropUrl(backdropUrl),
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.5),
              decodeWidth: MediaQuery.sizeOf(context).width,
              fadeInDuration: AppMotion.emphasis,
              placeholder: const ColoredBox(color: page),
              errorWidget: const ColoredBox(color: page),
            ),
          ),
          // Vignettage, comme un écran de cinéma.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 1.1,
                colors: [
                  Colors.black.withValues(alpha: 0),
                  Colors.black.withValues(alpha: 0.45),
                ],
                stops: const [0.6, 1],
              ),
            ),
          ),
          // Lisibilité du titre et des boutons. En téléphone, le texte passe
          // sous l'image : seul le fondu du bas sert.
          if (!compact)
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: 0.7,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      page,
                      page.withValues(alpha: 0.75),
                      page.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  page.withValues(alpha: 0.5),
                  page.withValues(alpha: 0),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 192,
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      page.withValues(alpha: 0.85),
                      page.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  page,
                  page.withValues(alpha: 0.55),
                  page.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Le style d'une pastille d'action de la fiche.
enum HeroPillStyle {
  /// Verre blanc à 15 %, arête éclairée : « Demander », « Compléter ».
  glass,

  /// Monochrome : l'état se lit à l'icône et au mouvement plus qu'à la couleur.
  status,

  /// Teinte rouge de la bande-annonce.
  trailer,
}

/// Une pastille d'action de la fiche, au gabarit d'OnyxHub
/// (`RequestStatusButton`) : arrondie, plus basse et plus serrée en téléphone.
///
/// Sans [onPressed], elle reste lisible mais ne prend pas le focus : un
/// statut n'est pas une action, la télécommande passe directement au bouton
/// suivant.
class HeroPill extends StatelessWidget {
  const HeroPill({
    super.key,
    required this.label,
    required this.style,
    this.icon,
    this.iconColor,
    this.onPressed,
    this.loading = false,
    this.beam = false,
    this.track = false,
    this.iconOnlyWhenCompact = false,
    this.dense = false,
  });

  final String label;
  final HeroPillStyle style;
  final IconData? icon;
  final Color? iconColor;
  final VoidCallback? onPressed;

  /// Une barre court sous le libellé (envoi en cours).
  final bool loading;

  /// Le faisceau qui traverse une fois une pastille « Disponible ».
  final bool beam;

  /// La barre ambre sous « En cours de traitement ».
  final bool track;

  /// En téléphone, l'icône seule dans un rond (la bande-annonce).
  final bool iconOnlyWhenCompact;

  /// La petite pastille posée dans une carte (« Demander » d'une saison) :
  /// même verre, gabarit de téléphone quelle que soit la largeur.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final compact = dense || AppLayout.isCompact(context);
    final (fill, border, foreground) = switch (style) {
      HeroPillStyle.glass => (
          Colors.white.withValues(alpha: 0.15),
          Colors.white.withValues(alpha: 0.2),
          AppColors.textPrimary,
        ),
      HeroPillStyle.status => (
          Colors.white.withValues(alpha: 0.06),
          Colors.white.withValues(alpha: 0.1),
          AppColors.textPrimary,
        ),
      HeroPillStyle.trailer => (
          AppColors.error.withValues(alpha: 0.1),
          AppColors.error.withValues(alpha: 0.22),
          AppColors.error,
        ),
    };
    final iconOnly = !dense && compact && iconOnlyWhenCompact && icon != null;
    final iconSize = dense ? 14.0 : (compact ? 16.0 : 20.0);
    final hasBar = loading || track;

    Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          Icon(icon, size: iconSize, color: iconColor ?? foreground),
        if (icon != null && !iconOnly) SizedBox(width: compact ? 6 : 9),
        if (!iconOnly)
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontWeight: FontWeight.w600,
              fontSize: dense
                  ? AppType.footnote
                  : (compact ? AppType.subhead : AppType.callout),
            ),
          ),
      ],
    );
    content = Padding(
      padding: iconOnly
          ? const EdgeInsets.all(12)
          : dense
              ? EdgeInsets.fromLTRB(11, 6, 12, 6 + (hasBar ? 4 : 0))
              : EdgeInsets.fromLTRB(compact ? 14 : 24, compact ? 10 : 13,
                  compact ? 14 : 24, (compact ? 10 : 13) + (hasBar ? 4 : 0)),
      child: content,
    );

    final pill = Material(
      color: fill,
      shape: StadiumBorder(side: BorderSide(color: border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        canRequestFocus: onPressed != null,
        customBorder: const StadiumBorder(),
        child: Stack(
          children: [
            content,
            if (beam) const Positioned.fill(child: StatusBeam()),
            if (hasBar)
              Positioned(
                left: dense ? 11 : (compact ? 14 : 24),
                right: dense ? 12 : (compact ? 14 : 24),
                bottom: dense ? 4 : (compact ? 6 : 8),
                child:
                    loading ? const _InkTrack() : const StatusTrack(height: 3),
              ),
          ],
        ),
      ),
    );
    return iconOnly ? Tooltip(message: label, child: pill) : pill;
  }
}

/// La barre d'envoi, à l'encre de l'app plutôt qu'à l'ambre du statut.
class _InkTrack extends StatelessWidget {
  const _InkTrack();

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return const SizedBox.shrink();
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          minHeight: 3,
          color: AppColors.textPrimary,
          backgroundColor: Colors.white.withValues(alpha: 0.08),
        ),
      ),
    );
  }
}

/// Le cadre d'import sous les boutons, comme celui d'OnyxHub : une pastille
/// ambre, le message du serveur et l'étiquette « Importation ».
class RequestImportNotice extends StatelessWidget {
  const RequestImportNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 4),
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppColors.warning,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: AppColors.warning,
                  fontWeight: FontWeight.w600,
                  fontSize: AppType.footnote,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: AppColors.warning.withValues(alpha: 0.2)),
              ),
              child: Text(
                tr('Importation').toUpperCase(),
                style: TextStyle(
                  color: AppColors.warning.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w700,
                  fontSize: AppType.micro,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un bouton rond secondaire (« Ajouter à une liste »), à côté des pastilles :
/// verre à 5 %, filet blanc, la taille des pastilles.
ButtonStyle heroRoundButtonStyle(BuildContext context, ButtonStyle base) {
  final size = AppLayout.isCompact(context) ? 42.0 : 48.0;
  return base.copyWith(
    fixedSize: WidgetStatePropertyAll(Size(size, size)),
    minimumSize: WidgetStatePropertyAll(Size(size, size)),
    backgroundColor:
        WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.05)),
    side: WidgetStatePropertyAll(
        BorderSide(color: Colors.white.withValues(alpha: 0.1))),
    iconSize: const WidgetStatePropertyAll(20),
  );
}
