import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_type.dart';
import '../../utils/responsive.dart';
import 'app_network_image.dart';
import 'detail_metadata.dart';
import 'detail_synopsis.dart';
import 'media_logo_display.dart';
import 'overlay_back_button.dart';
import 'poster_flight.dart';
import 'staggered_entrance.dart';
import 'status_motion.dart';

/// Le fond d'une fiche, sous son en-tête : l'image décodée à la largeur de la
/// fenêtre, un fondu vers la page en bas et un voile derrière le texte.
class DetailBackdrop extends StatelessWidget {
  const DetailBackdrop({super.key, required this.url});

  /// L'adresse déjà résolue (`detailBackdropUrl`).
  final String? url;

  static const double heightDesktop = 540;

  /// La hauteur de l'en-tête : l'envol de l'affiche vise ce cadre.
  static double heightFor(BuildContext context) {
    if (!AppLayout.isCompact(context)) return heightDesktop;
    return (MediaQuery.sizeOf(context).height * 0.62).clamp(420.0, 520.0);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: heightFor(context),
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Decoded at window width, not at the source's 1280 px: the backdrop
          // is the largest image on the page and the one that used to hold up
          // the first paint.
          AppNetworkImage(
            url: url,
            fit: BoxFit.cover,
            alignment: PosterFlight.focus,
            filterQuality: FilterQuality.high,
            decodeWidth: MediaQuery.sizeOf(context).width,
            fadeInDuration: AppMotion.standard,
            placeholder: const ColoredBox(color: AppColors.surfaceElevated),
            errorWidget: const ColoredBox(color: AppColors.surfaceElevated),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.transparent,
                  AppColors.background,
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
          ),
          if (!AppLayout.isCompact(context))
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    AppColors.background.withValues(alpha: 0.95),
                    AppColors.background.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 0.85],
                ),
              ),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.25),
                    AppColors.background.withValues(alpha: 0.75),
                    AppColors.background,
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// L'en-tête de toutes les fiches (film, série, saison, demande) : le fond,
/// l'affiche à gauche, puis le surtitre, le logo, l'accroche, les métadonnées,
/// le synopsis et les actions, qui tombent en place quand l'envol de l'affiche
/// atterrit.
class DetailHero extends StatelessWidget {
  const DetailHero({
    super.key,
    required this.backdropUrl,
    required this.posterUrl,
    required this.logoUrl,
    required this.title,
    required this.playKey,
    this.eyebrow,
    this.tagline,
    this.overview,
    this.emptyOverviewLabel,
    this.metadata = const [],
    this.badges = const [],
    this.actions,
    this.onBack,
  });

  /// Adresses déjà résolues (`detailBackdropUrl`, `detailPosterUrl`,
  /// `logoImageUrl`).
  final String? backdropUrl;
  final String? posterUrl;
  final String? logoUrl;
  final String title;

  /// Ce qui rejoue l'arrivée en cascade : l'identité du titre.
  final Object playKey;

  final Widget? eyebrow;
  final String? tagline;
  final String? overview;

  /// Ce que l'en-tête écrit à la place d'un synopsis absent.
  final String? emptyOverviewLabel;

  /// Voir [buildMetadataChips].
  final List<Widget> metadata;

  /// Voir [techBadgesFor].
  final List<String> badges;
  final Widget? actions;

  /// Nul quand il n'y a rien derrière la page : celle d'un lien de partage.
  final VoidCallback? onBack;

  /// Marges de l'affiche dans l'en-tête : en bas elle s'aligne sur le texte,
  /// en haut elle laisse passer le bouton retour.
  static const double _posterBottom = 36;
  static const double _posterTop = 116;

  /// Sur grand écran l'affiche monte jusque sous le bouton retour, avec un
  /// peu d'air : collée en haut, elle passait dessous.
  static const double posterHeight =
      DetailBackdrop.heightDesktop - _posterBottom - _posterTop;
  static const double posterWidth = posterHeight * 2 / 3;

  /// Sur tablette, la grande affiche ne laisserait pas sa largeur au texte.
  static const double posterHeightMedium = 285;

  /// Largeur de lecture du synopsis sur grand écran.
  static const double overviewMaxWidth = 720;

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    final pad = AppLayout.pagePadding(context);
    final info = _info(context, compact);

    final header = Stack(
      children: [
        DetailBackdrop(url: backdropUrl),
        Positioned(
          left: pad,
          right: pad,
          bottom: compact ? 20 : _posterBottom,
          child: FlightDrop(
            delay: const Duration(milliseconds: 170),
            child: compact
                ? info
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _Poster(
                        url: posterUrl,
                        height: AppLayout.isWide(context)
                            ? posterHeight
                            : posterHeightMedium,
                      ),
                      const SizedBox(width: 36),
                      Expanded(child: info),
                    ],
                  ),
          ),
        ),
        if (onBack != null)
          Positioned(
            top: 4,
            left: 8,
            child: FlightDrop(child: OverlayBackButton(onPressed: onBack)),
          ),
      ],
    );

    if (actions == null || !compact) return header;
    // Sur téléphone, les actions passent sous l'image plutôt que dessus : le
    // titre, le logo, les puces et quatre lignes de synopsis remplissent déjà
    // l'en-tête, et un bouton pleine largeur de plus le faisait remonter
    // jusque sous le bouton retour.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 8),
          child: FlightDrop(
            delay: const Duration(milliseconds: 170),
            child: actions!,
          ),
        ),
      ],
    );
  }

  Widget _info(BuildContext context, bool compact) {
    final overview = this.overview;
    return StaggeredEntranceScope(
      playKey: playKey,
      maxAnimated: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          StaggeredEntrance(
            index: 0,
            child: eyebrow == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: eyebrow,
                  ),
          ),
          StaggeredEntrance(
            index: 1,
            child: MediaLogoDisplay(
              title: title,
              logoUrl: logoUrl,
              maxHeight: compact ? 72 : 160,
              maxWidth: compact ? double.infinity : 420,
              textStyle: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                    fontSize: compact ? 26 : null,
                  ),
            ),
          ),
          StaggeredEntrance(
            index: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tagline != null && tagline!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    tagline!,
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppType.body,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                if (metadata.isNotEmpty || badges.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (var i = 0; i < metadata.length; i++) ...[
                        if (i > 0) const MetadataDot(),
                        metadata[i],
                      ],
                      if (badges.isNotEmpty) ...[
                        if (metadata.isNotEmpty) const SizedBox(width: 4),
                        for (final badge in badges) TechBadge(badge),
                      ],
                    ],
                  ),
                ],
                if (overview != null && overview.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: compact ? double.infinity : overviewMaxWidth),
                    child: DetailSynopsis(
                      title: title,
                      overview: overview,
                      maxLines: compact ? 4 : 3,
                    ),
                  ),
                ] else if (emptyOverviewLabel != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    emptyOverviewLabel!,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: AppType.body,
                    ),
                  ),
                ],
              ],
            ),
          ),
          StaggeredEntrance(
            index: 3,
            child: actions == null || compact
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 22),
                    child: actions,
                  ),
          ),
        ],
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final String? url;
  final double height;

  const _Poster({required this.url, required this.height});

  @override
  Widget build(BuildContext context) {
    final h = height;
    final w = h * 2 / 3;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AppNetworkImage(
          url: url,
          width: w,
          height: h,
          fit: BoxFit.cover,
          errorWidget: Container(
            width: w,
            height: h,
            color: AppColors.surfaceElevated,
            child: const Icon(AppIcons.movie,
                size: 48, color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}

/// Le style d'une pastille d'action de la fiche.
enum HeroPillStyle {
  /// Verre blanc à 15 %, arête éclairée : « Lecture », « Demander ».
  glass,

  /// Monochrome : l'état se lit à l'icône et au mouvement plus qu'à la couleur.
  status,

  /// Teinte rouge de la bande-annonce.
  trailer,

  /// Bleu plein de « Demander » sur une saison pas encore demandée, comme
  /// MediaHub (`SeasonRequestButton`).
  request,
}

/// Une pastille d'action de la fiche, au gabarit d'OnyxHub
/// (`RequestStatusButton`) : arrondie, plus basse et plus serrée en téléphone.
///
/// Sans [onPressed], elle reste lisible mais ne prend pas le focus : un
/// statut n'est pas une action, la télécommande passe directement au bouton
/// suivant.
class HeroPill extends StatefulWidget {
  const HeroPill({
    super.key,
    required this.label,
    required this.style,
    this.icon,
    this.iconColor,
    this.onPressed,
    this.autofocus = false,
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

  /// La télécommande arrive ici à l'ouverture de la fiche.
  final bool autofocus;

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
  State<HeroPill> createState() => _HeroPillState();
}

class _HeroPillState extends State<HeroPill> {
  /// Le voile de focus d'un `InkWell` ne se lit pas depuis un canapé sur du
  /// verre : l'arête passe à l'accent, comme le liseré des affiches (ADR-0008).
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final compact = widget.dense || AppLayout.isCompact(context);
    final (fill, border, foreground) = switch (widget.style) {
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
      HeroPillStyle.request => (
          AppColors.request,
          Colors.white.withValues(alpha: 0.25),
          Colors.white,
        ),
    };
    final iconOnly = !widget.dense &&
        compact &&
        widget.iconOnlyWhenCompact &&
        widget.icon != null;
    final iconSize = widget.dense ? 14.0 : (compact ? 16.0 : 20.0);
    final hasBar = widget.loading || widget.track;

    Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.icon != null)
          Icon(widget.icon,
              size: iconSize, color: widget.iconColor ?? foreground),
        if (widget.icon != null && !iconOnly) SizedBox(width: compact ? 6 : 9),
        if (!iconOnly)
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w600,
                fontSize: widget.dense
                    ? AppType.footnote
                    : (compact ? AppType.subhead : AppType.callout),
              ),
            ),
          ),
      ],
    );
    content = Padding(
      padding: iconOnly
          ? const EdgeInsets.all(12)
          : widget.dense
              ? EdgeInsets.fromLTRB(11, 6, 12, 6 + (hasBar ? 4 : 0))
              : EdgeInsets.fromLTRB(compact ? 14 : 24, compact ? 10 : 13,
                  compact ? 14 : 24, (compact ? 10 : 13) + (hasBar ? 4 : 0)),
      child: content,
    );

    final pill = Material(
      color: fill,
      shape: StadiumBorder(
        side: _focused
            ? const BorderSide(color: AppColors.accent, width: 3)
            : BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onPressed,
        autofocus: widget.autofocus,
        canRequestFocus: widget.onPressed != null,
        onFocusChange: (focused) => setState(() => _focused = focused),
        customBorder: const StadiumBorder(),
        child: Stack(
          // Centré quand la colonne du téléphone l'étire sur toute la largeur.
          alignment: Alignment.center,
          children: [
            content,
            if (widget.beam) const Positioned.fill(child: StatusBeam()),
            if (hasBar)
              Positioned(
                left: widget.dense ? 11 : (compact ? 14 : 24),
                right: widget.dense ? 12 : (compact ? 14 : 24),
                bottom: widget.dense ? 4 : (compact ? 6 : 8),
                child: widget.loading
                    ? const _InkTrack()
                    : const StatusTrack(height: 3),
              ),
          ],
        ),
      ),
    );
    if (widget.style == HeroPillStyle.request) {
      // La lueur bleue sous la pastille, comme `shadow-[0_6px_18px_-8px]` chez MediaHub.
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: AppColors.request.withValues(alpha: 0.5),
              blurRadius: 18,
              spreadRadius: -8,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: pill,
      );
    }
    return iconOnly ? Tooltip(message: widget.label, child: pill) : pill;
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
