import 'dart:async';

import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus.dart';
import 'app_network_image.dart';

/// Single poster card used by every catalog grid (films, séries, bibliothèque,
/// demandes). The poster fills the whole grid cell above the metadata block, so
/// the cell's aspect ratio — not a hardcoded height — decides the poster size.
class PosterCard extends StatefulWidget {
  /// Fully resolved image URL (see `cardPosterUrl`). Null renders the fallback.
  ///
  /// This doubles as the cache identity: two cards showing the same artwork
  /// share one download and one decode, wherever in the app they live.
  final String? posterUrl;
  final String title;

  /// Secondary line (année · note · rôle…). Rendered even when empty so every
  /// card in a grid keeps the same baseline.
  final String? subtitle;
  final VoidCallback onTap;

  /// Badges / dots stacked over the poster (already `Positioned`).
  final List<Widget> overlays;

  /// Overlay posé en bas de l'affiche (progression…), en retrait des bords.
  ///
  /// Le retrait n'est pas cosmétique : une bande collée au bord bas devrait se
  /// faire découper par l'arrondi du coin, et son rayon à elle plus celui de
  /// l'affiche se lisaient comme deux coins mal alignés. Elle flotte donc à
  /// l'intérieur, comme les badges du haut, avec le même retrait qu'eux.
  final Widget? footerOverlay;

  /// Dims the poster for titles absent from the library.
  final bool dimmed;

  /// Play affordance revealed on hover — only for playable local content.
  final bool showPlayOnHover;
  final IconData placeholderIcon;
  final bool compact;

  /// Takes the remote's focus as soon as the card is built. One card per screen
  /// sets this — the first poster of the first row — so a television lands on
  /// the content instead of on whatever the traversal policy sorts first.
  final bool autofocus;

  /// Called when the user settles on the card (hover, remote focus, press) —
  /// the moment to warm what [onTap] is about to open. See `DetailPrefetch`.
  final VoidCallback? onPrefetch;

  const PosterCard({
    super.key,
    required this.posterUrl,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.overlays = const [],
    this.footerOverlay,
    this.dimmed = false,
    this.showPlayOnHover = false,
    this.placeholderIcon = Icons.movie_outlined,
    this.compact = false,
    this.autofocus = false,
    this.onPrefetch,
  });

  static const double radius = 12;

  /// Retrait commun à tout ce qui flotte au-dessus de l'affiche — badges et
  /// barre de progression — pour que rien ne vienne toucher l'arrondi.
  static const double overlayInset = 9;

  /// Combien l'affiche déborde de chaque côté quand elle se soulève. Les
  /// grilles et rangées espacent leurs cartes d'au moins 10 px : avec 4 px de
  /// part et d'autre, deux voisines en pleine transition (l'une qui monte,
  /// l'autre qui redescend) ne se touchent jamais.
  static const double liftOverflow = 4;

  /// Marge à réserver au-dessus d'une rangée horizontale : le zoom est ancré
  /// vers le bas de l'affiche (pour ne pas mordre sur le titre), donc l'essentiel
  /// du débord part vers le haut, là où le viewport de la liste couperait.
  static const double liftHeadroom = 10;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;
  bool _focused = false;

  /// Hover and D-pad focus are the same state as far as this card is concerned:
  /// "the user is pointing at me". One flag drives one highlight, so the mouse
  /// and the remote never disagree about which card is live.
  bool get _active => _hovered || _focused;

  Timer? _prefetchTimer;

  /// How long the pointer (or the remote's focus) has to rest on the card
  /// before [PosterCard.onPrefetch] fires. Sweeping across a row does not
  /// warm every title it crosses; stopping on one does, a few hundred ms
  /// before the click.
  static const Duration _prefetchIntent = Duration(milliseconds: 120);

  void _schedulePrefetch() {
    if (widget.onPrefetch == null) return;
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(_prefetchIntent, _prefetchNow);
  }

  void _cancelPrefetch() {
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
  }

  void _prefetchNow() {
    _cancelPrefetch();
    if (mounted) widget.onPrefetch?.call();
  }

  @override
  void dispose() {
    _cancelPrefetch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;

    return TvFocusable(
      onSelect: widget.onTap,
      autofocus: widget.autofocus,
      borderRadius: BorderRadius.circular(PosterCard.radius),
      // The artwork lights up on its own below; a ring around the title lines
      // as well would double the outline.
      showRing: false,
      onFocusChange: (focused) {
        if (_focused == focused) return;
        setState(() => _focused = focused);
        focused ? _schedulePrefetch() : _cancelPrefetch();
      },
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _hovered = true);
          _schedulePrefetch();
        },
        onExit: (_) {
          setState(() => _hovered = false);
          _cancelPrefetch();
        },
        child: InkWell(
          onTap: widget.onTap,
          // Touch has no hover: the press itself is the earliest signal, a
          // hundred-odd ms before the tap is confirmed.
          onTapDown:
              widget.onPrefetch == null ? null : (_) => _prefetchNow(),
          // The wrapper above owns the focus. Leaving the ink well focusable too
          // would put two stops on every card, so the remote would need two
          // presses to cross one poster.
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(PosterCard.radius),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: PosterLift(
                  active: _active,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(PosterCard.radius),
                        child: _poster(),
                      ),
                      PosterHoverOverlay(
                        active: _active,
                        focused: _focused,
                        showPlay: widget.showPlayOnHover,
                        playSize: compact ? 44 : 50,
                      ),
                      ...widget.overlays,
                      if (widget.footerOverlay != null)
                        Positioned(
                          left: PosterCard.overlayInset,
                          right: PosterCard.overlayInset,
                          bottom: PosterCard.overlayInset,
                          child: widget.footerOverlay!,
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: compact ? 7 : 9),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 13 : 14,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  letterSpacing: -0.1,
                  color: widget.dimmed
                      ? AppColors.textSecondary
                      : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.subtitle ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 11 : 12,
                  height: 1.2,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _poster() {
    return AppNetworkImage(
      url: widget.posterUrl,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 180),
      color: widget.dimmed ? Colors.black.withValues(alpha: 0.45) : null,
      colorBlendMode: widget.dimmed ? BlendMode.darken : null,
      placeholder: const ColoredBox(color: AppColors.surfaceElevated),
      errorWidget: _fallback(broken: widget.posterUrl?.isNotEmpty ?? false),
    );
  }

  Widget _fallback({bool broken = false}) {
    return ColoredBox(
      color: AppColors.surfaceElevated,
      child: Center(
        child: Icon(
          broken ? Icons.broken_image_outlined : widget.placeholderIcon,
          color: AppColors.textMuted,
          size: 42,
        ),
      ),
    );
  }
}

/// Durée commune aux animations de survol des affiches. Coupée net quand le
/// système demande de réduire les animations.
Duration _posterMotion(BuildContext context, Duration base) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
        ? Duration.zero
        : base;

/// Soulève une affiche quand elle est pointée : un léger zoom et une ombre qui
/// s'épaissit, comme si elle sortait de l'écran.
///
/// Le zoom est calculé en pixels plutôt qu'en pourcentage, pour que le débord
/// ([PosterCard.liftOverflow]) reste le même d'une petite carte de rangée à une
/// grande carte de grille — et ne vienne jamais toucher la voisine.
class PosterLift extends StatelessWidget {
  final bool active;
  final Widget child;

  const PosterLift({super.key, required this.active, required this.child});

  static const Duration duration = Duration(milliseconds: 260);

  /// Point fixe du zoom : aux trois quarts de la hauteur, l'affiche grandit
  /// surtout vers le haut et à peine vers le titre en dessous.
  static const Alignment anchor = Alignment(0, 0.5);

  @override
  Widget build(BuildContext context) {
    final motion = _posterMotion(context, duration);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final lifted = width.isFinite && width > 0
            ? (1 + PosterCard.liftOverflow * 2 / width).clamp(1.0, 1.06)
            : 1.0;

        return AnimatedScale(
          scale: active ? lifted : 1.0,
          alignment: anchor,
          duration: motion,
          curve: active ? Curves.easeOutCubic : Curves.easeOutQuart,
          child: AnimatedContainer(
            duration: motion,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(PosterCard.radius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: active ? 0.55 : 0.0),
                  blurRadius: active ? 22 : 8,
                  spreadRadius: active ? -4 : -6,
                  offset: Offset(0, active ? 12 : 4),
                ),
              ],
            ),
            child: child,
          ),
        );
      },
    );
  }
}

/// Ce qui se pose sur l'affiche pointée : un voile qui s'assombrit vers le bas,
/// le bouton lecture qui éclot au centre et le liseré de sélection.
///
/// Tout reste monté et s'anime en fondu : un voile qui apparaissait d'un coup
/// clignotait à chaque passage de souris sur une rangée.
class PosterHoverOverlay extends StatelessWidget {
  final bool active;

  /// Focus télécommande : le liseré passe à l'accent en pleine épaisseur, pour
  /// se lire depuis le canapé plutôt que le filet discret de la souris.
  final bool focused;

  /// Voile + bouton lecture — seulement pour ce qui se lance directement.
  final bool showPlay;
  final double playSize;

  const PosterHoverOverlay({
    super.key,
    required this.active,
    this.focused = false,
    this.showPlay = true,
    this.playSize = 50,
  });

  static const Duration _fade = Duration(milliseconds: 220);
  static const Duration _pop = Duration(milliseconds: 280);

  @override
  Widget build(BuildContext context) {
    final fade = _posterMotion(context, _fade);
    final pop = _posterMotion(context, _pop);
    final radius = BorderRadius.circular(PosterCard.radius);

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showPlay)
            AnimatedOpacity(
              opacity: active ? 1 : 0,
              duration: fade,
              curve: Curves.easeOutCubic,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  // Plus léger en haut, où sont les visages et le titre de
                  // l'affiche ; plus dense en bas, sous le bouton et la barre
                  // de progression qui doivent ressortir.
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.12),
                      Colors.black.withValues(alpha: 0.30),
                      Colors.black.withValues(alpha: 0.62),
                    ],
                    stops: const [0, 0.55, 1],
                  ),
                ),
              ),
            ),
          if (showPlay)
            Center(
              child: AnimatedOpacity(
                opacity: active ? 1 : 0,
                duration: fade,
                curve: Curves.easeOutCubic,
                child: AnimatedScale(
                  scale: active ? 1 : 0.7,
                  duration: pop,
                  curve: active ? Curves.easeOutBack : Curves.easeInCubic,
                  child: _PlayDisc(size: playSize),
                ),
              ),
            ),
          AnimatedContainer(
            duration: fade,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: !active
                    ? Colors.white.withValues(alpha: 0)
                    : focused
                        ? AppColors.accent
                        : Colors.white.withValues(alpha: 0.22),
                width: focused ? 3 : 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayDisc extends StatelessWidget {
  final double size;

  const _PlayDisc({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.96),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      // Le triangle est décalé à l'œil : centré au pixel, il paraît pencher
      // vers la gauche dans son disque.
      child: Padding(
        padding: EdgeInsets.only(left: size * 0.06),
        child: Icon(
          Icons.play_arrow_rounded,
          size: size * 0.62,
          color: Colors.black.withValues(alpha: 0.88),
        ),
      ),
    );
  }
}
