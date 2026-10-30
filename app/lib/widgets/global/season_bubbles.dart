import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_focus.dart';
import '../../tv/tv_focus_memory.dart';
import 'app_network_image.dart';
import 'season_liquid.dart';

/// Diamètre d'une bulle de saison fermée, et marge entre deux bulles.
const _bubbleSize = 48.0;
const _bubbleGap = 12.0;

/// Une saison telle que la rangée de bulles la montre.
class SeasonBubbleEntry {
  /// Son identité dans la rangée, celle que reçoit [SeasonBubbleRow.onTap].
  final int id;

  /// Le numéro écrit sur la bulle fermée (« 2 », « SP »).
  final String code;

  /// Le nom et le détail, écrits sur la bulle ouverte.
  final String title;
  final String detail;

  /// Ce que lit un lecteur d'écran : le numéro seul ne dit rien, et le sablier
  /// encore moins.
  final String semanticLabel;
  final String? posterUrl;

  /// Demandée à MediaHub, pas encore toute là : le sablier orange. Une saison
  /// disponible ne porte rien, et une saison à demander non plus : c'est en la
  /// dépliant qu'on la demande.
  final bool requested;

  /// Absente du serveur, et pas demandée : son numéro s'efface.
  final bool missing;

  /// Le message au survol, pour une rangée qui n'a pas de fiche à y ouvrir.
  final String? tooltip;

  const SeasonBubbleEntry({
    required this.id,
    required this.code,
    required this.title,
    required this.detail,
    required this.semanticLabel,
    this.posterUrl,
    this.requested = false,
    this.missing = false,
    this.tooltip,
  });
}

/// Les saisons d'une série, comme sur OnyxHub (`SeasonList`) : une bulle de
/// verre par saison sur une seule ligne. La bulle [selected] se gonfle en
/// pilule (affiche, nom, nombre d'épisodes).
///
/// Changer de saison lâche une goutte qui file d'une bulle à l'autre
/// (`season_liquid.dart`) : la bulle quittée se retracte, la choisie se gonfle
/// en rebondissant quand la goutte l'atteint, et ne s'éclaire qu'à ce moment.
/// Pas de filtre de fusion comme chez OnyxHub : un seul chemin peint, supprimé
/// en mode léger (ADR-0086).
///
/// C'est l'appelant qui décide de la saison ouverte : la fiche d'une demande
/// déroule un panneau, celle d'une série sa liste d'épisodes.
class SeasonBubbleRow extends StatefulWidget {
  final List<SeasonBubbleEntry> entries;
  final int? selected;
  final ValueChanged<int> onTap;

  /// Habille une bulle : l'aperçu au survol d'une saison de la bibliothèque.
  final Widget Function(SeasonBubbleEntry entry, Widget bubble)? wrap;

  /// Le cadre sous la rangée et l'abscisse qu'il y lit : la lumière de son bord
  /// haut se pose sous la bulle ouverte. Une notification plutôt qu'un
  /// `setState` : seule la lumière se redessine quand la bulle bouge.
  final GlobalKey? frameKey;
  final ValueNotifier<double?>? beamX;

  const SeasonBubbleRow({
    super.key,
    required this.entries,
    required this.selected,
    required this.onTap,
    this.wrap,
    this.frameKey,
    this.beamX,
  });

  @override
  State<SeasonBubbleRow> createState() => _SeasonBubbleRowState();
}

class _SeasonBubbleRowState extends State<SeasonBubbleRow>
    with SingleTickerProviderStateMixin {
  final _rowKey = GlobalKey();
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _bubbleKeys = {};

  /// Tourne le temps que les bulles changent de largeur, pour que la lumière
  /// suive la bulle ouverte au lieu d'attendre qu'elle ait fini de bouger.
  late final AnimationController _follow;

  /// La bulle éclairée : la choisie, mais seulement une fois la goutte arrivée.
  int? _lit;

  /// La saison quittée au dernier changement : sa bulle se retracte.
  int? _from;

  /// Part de l'animation (0 à 1) après laquelle la goutte a atteint la bulle
  /// choisie, qui s'éclaire alors.
  double _inflateAt = 0;

  /// Durée du dernier changement, en secondes, et les ressorts qui en
  /// découlent pour la bulle choisie et la bulle quittée.
  double _span = 0.7;
  Curve _grow = const SeasonSpring.grow(span: 0.7);
  Curve _shrink = const SeasonSpring.shrink(span: 0.7);

  /// La goutte en route, nulle quand rien ne voyage.
  SeasonDropPlan? _plan;

  @override
  void initState() {
    super.initState();
    _lit = widget.selected;
    // Créé ici et non à la première lecture : un `late final` paresseux
    // naîtrait dans `dispose` si aucune saison n'a jamais été ouverte.
    _follow = AnimationController(vsync: this)
      ..addListener(_measureAfterFrame)
      ..addListener(_lightWhenReached)
      ..addStatusListener(_followStatus);
    _scroll.addListener(_measureAfterFrame);
    if (widget.selected != null) _measureAfterFrame();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _follow.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SeasonBubbleRow old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _travel(old.selected, widget.selected);
  }

  /// La goutte part du centre de la bulle quittée : la rangée n'a pas encore
  /// changé quand on la mesure ici.
  void _travel(int? previous, int? next) {
    final travelling = previous != null && next != null;
    SeasonDropPlan? plan;
    if (travelling && !AppMotion.reduced(context)) {
      final from = _bubbleRect(previous);
      final to = _bubbleRect(next);
      if (from != null && to != null) {
        _span = 0.9;
        plan = SeasonDropPlan(
          origin: from.center.dx,
          target: to.left + _bubbleSize / 2,
          span: _span,
        );
      }
    }
    if (plan == null) _span = 0.7;
    _inflateAt = plan == null ? 0 : 0.36;
    _grow = SeasonSpring.grow(span: _span, delay: _inflateAt * _span);
    _shrink = SeasonSpring.shrink(span: _span);
    _from = previous;
    _plan = plan;
    // Avec une goutte, la bulle choisie attend qu'elle l'atteigne.
    _lit = plan == null ? next : null;
    if (next == null) return;
    _follow.duration = AppMotion.move(
      context,
      Duration(milliseconds: (_span * 1000).round()),
    );
    _follow.forward(from: 0);
    _measureAfterFrame();
  }

  /// La goutte a atteint la bulle choisie : elle s'éclaire.
  void _lightWhenReached() {
    if (!mounted || _lit == widget.selected || widget.selected == null) return;
    if (_follow.value >= _inflateAt) setState(() => _lit = widget.selected);
  }

  /// Le rectangle d'une bulle dans la rangée, ou nul si elle n'est pas posée.
  Rect? _bubbleRect(int? id) {
    final box = _bubbleKeys[id]?.currentContext?.findRenderObject();
    final row = _rowKey.currentContext?.findRenderObject();
    if (box is! RenderBox || row is! RenderBox) return null;
    if (!box.attached || !row.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: row) & box.size;
  }

  void _followStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_plan != null || _lit != widget.selected) {
      setState(() {
        _plan = null;
        _lit = widget.selected;
      });
    }
    // La bulle a pris sa largeur : c'est maintenant qu'on sait si elle dépasse.
    final bubble = _bubbleKeys[widget.selected]?.currentContext;
    if (bubble != null) {
      Scrollable.ensureVisible(
        bubble,
        duration: AppMotion.move(context, AppMotion.standard),
        curve: AppMotion.curve,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
    _measureAfterFrame();
  }

  void _measureAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureBeam();
      // Seulement pendant le trajet : sinon la rangée se rebloquerait sur la
      // bulle ouverte chaque fois que l'utilisateur essaie de la dépasser au
      // défilement manuel.
      if (_follow.isAnimating) _followScroll();
    });
  }

  /// Garde la bulle choisie dans le cadre visible tout le temps qu'elle
  /// grossit, au lieu d'attendre la fin du trajet pour y sauter d'un coup
  /// (`Scrollable.ensureVisible` dans [_followStatus] ne faisait que ça).
  void _followScroll() {
    if (!mounted || !_scroll.hasClients) return;
    final rect = _bubbleRect(widget.selected);
    if (rect == null) return;
    final position = _scroll.position;
    const margin = 8.0;
    double target;
    if (rect.left < position.pixels + margin) {
      target = rect.left - margin;
    } else if (rect.right > position.pixels + position.viewportDimension) {
      target = rect.right - position.viewportDimension + margin;
    } else {
      return;
    }
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.5) return;
    position.jumpTo(target);
  }

  void _measureBeam() {
    final beamX = widget.beamX;
    if (!mounted || widget.selected == null || beamX == null) return;
    final bubble =
        _bubbleKeys[widget.selected]?.currentContext?.findRenderObject();
    final frame = widget.frameKey?.currentContext?.findRenderObject();
    if (bubble is! RenderBox ||
        frame is! RenderBox ||
        !bubble.attached ||
        !frame.attached) {
      return;
    }
    final center = bubble.localToGlobal(bubble.size.center(Offset.zero));
    final x = frame.globalToLocal(center).dx;
    if (beamX.value == null || (beamX.value! - x).abs() >= 0.5) {
      beamX.value = x;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final wrap = widget.wrap;
    // La rangée se souvient de la bulle où était la télécommande.
    return TvFocusMemory(
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        // La lueur de la bulle ouverte déborde de sa boîte : de l'air autour
        // pour que le défilement ne la coupe pas.
        padding: const EdgeInsets.symmetric(vertical: 8),
        clipBehavior: Clip.none,
        child: Stack(
          key: _rowKey,
          clipBehavior: Clip.none,
          children: [
            Row(
              children: [
                for (final entry in entries) ...[
                  Builder(builder: (context) {
                    final bubble = _SeasonBubble(
                      key: _bubbleKeys.putIfAbsent(entry.id, GlobalKey.new),
                      entry: entry,
                      selected: widget.selected == entry.id,
                      lit: _lit == entry.id,
                      duration: Duration(milliseconds: (_span * 1000).round()),
                      curve: widget.selected == entry.id ? _grow : _shrink,
                      onTap: () => widget.onTap(entry.id),
                    );
                    return wrap == null ? bubble : wrap(entry, bubble);
                  }),
                  if (entry != entries.last) const SizedBox(width: _bubbleGap),
                ],
              ],
            ),
            if (_plan case final plan?)
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: SeasonDropPainter(
                        clock: _follow,
                        plan: plan,
                        targetX: () {
                          final rect = _bubbleRect(widget.selected);
                          return rect == null
                              ? null
                              : rect.left + _bubbleSize / 2;
                        },
                        anchorX: () {
                          final rect = _bubbleRect(_from);
                          return rect == null
                              ? null
                              : rect.left + _bubbleSize / 2;
                        },
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Un `AnimatedSize` qui s'efface quand le mouvement est réduit : à durée
/// nulle, il se mute lui-même pendant sa mise en page.
class SeasonSizeTween extends StatelessWidget {
  final Duration duration;
  final Curve curve;
  final Alignment alignment;
  final Widget child;

  const SeasonSizeTween({
    super.key,
    required this.duration,
    required this.curve,
    required this.alignment,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) {
      return Align(
          alignment: alignment, widthFactor: 1, heightFactor: 1, child: child);
    }
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: alignment,
      child: child,
    );
  }
}

/// Une bulle de saison. Fermée, c'est un rond de verre avec son numéro et, si
/// la saison est demandée, un sablier ; ouverte, elle se gonfle en pilule qui
/// montre l'affiche, le nom et le nombre d'épisodes.
class _SeasonBubble extends StatelessWidget {
  final SeasonBubbleEntry entry;

  /// Ouverte : la bulle prend sa largeur de pilule.
  final bool selected;

  /// Éclairée : verre, affiche et nom apparaissent. Plus tard que [selected]
  /// quand une goutte voyage : elle doit d'abord atteindre la bulle.
  final bool lit;

  /// Durée et ressort de la largeur (`season_liquid.dart`).
  final Duration duration;
  final Curve curve;
  final VoidCallback onTap;

  const _SeasonBubble({
    super.key,
    required this.entry,
    required this.selected,
    required this.lit,
    required this.duration,
    required this.curve,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(_bubbleSize / 2));
    final bubble = SeasonSizeTween(
      duration: duration,
      curve: curve,
      alignment: Alignment.centerLeft,
      child: Stack(
        children: [
          AnimatedContainer(
            height: _bubbleSize,
            duration: AppMotion.fade(context, AppMotion.emphasis),
            curve: AppMotion.curve,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: lit ? 0.2 : 0.1),
              borderRadius: radius,
              border: Border.all(
                color: Colors.white.withValues(alpha: lit ? 0.32 : 0.14),
              ),
              boxShadow: [
                if (lit)
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.08),
                    blurRadius: 22,
                  ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                // Le focus est celui de [TvFocusable], autour de la bulle.
                canRequestFocus: false,
                customBorder: const StadiumBorder(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(6, 0, selected ? 0 : 6, 0),
                      child: _Lead(entry: entry, lit: lit),
                    ),
                    if (selected) _Label(entry: entry, lit: lit),
                  ],
                ),
              ),
            ),
          ),
          // Le sablier ou le nuage barré reste monté : il rentre dans la
          // bulle qui s'ouvre (échelle et fondu) et ressort quand elle se
          // ferme.
          if (entry.requested || entry.missing)
            Positioned(
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedScale(
                  scale: selected ? 0 : 1,
                  duration: AppMotion.move(context, AppMotion.standard),
                  curve: selected ? Curves.easeIn : Curves.easeOutBack,
                  child: AnimatedOpacity(
                    opacity: selected ? 0 : 1,
                    duration: AppMotion.fade(context, AppMotion.standard),
                    child: entry.requested
                        ? const _RequestedPip()
                        : const _MissingPip(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final tooltip = entry.tooltip;
    return Semantics(
      button: true,
      selected: selected,
      label: entry.semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: TvFocusable(
        onSelect: onTap,
        focusScale: 1.0,
        borderRadius: radius,
        child:
            tooltip == null ? bubble : Tooltip(message: tooltip, child: bubble),
      ),
    );
  }
}

/// Le rond de 34 px à gauche de la bulle : le numéro quand elle est fermée,
/// l'affiche de la saison quand elle est ouverte.
class _Lead extends StatelessWidget {
  final SeasonBubbleEntry entry;
  final bool lit;

  const _Lead({required this.entry, required this.lit});

  @override
  Widget build(BuildContext context) {
    final fade = AppMotion.fade(context, AppMotion.micro);
    return SizedBox.square(
      dimension: 34,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 1.5,
              ),
            ),
            child: const SizedBox.expand(),
          ),
          AnimatedScale(
            scale: lit ? 0.5 : 1,
            duration: AppMotion.move(context, AppMotion.emphasis),
            curve: AppMotion.curve,
            child: AnimatedOpacity(
              opacity: lit ? 0 : 1,
              duration: fade,
              child: Text(
                entry.code,
                style: TextStyle(
                  color:
                      entry.missing ? AppColors.textMuted : AppColors.primary,
                  fontSize: AppType.subhead,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          // L'affiche prend la place du numéro en rebondissant (ressort de
          // `--ease-spring` chez OnyxHub), sans rien monter tant que la
          // bulle est fermée.
          if (lit)
            Padding(
              padding: const EdgeInsets.all(3),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.4, end: 1),
                duration: AppMotion.move(context, AppMotion.emphasis),
                curve: Curves.easeOutBack,
                builder: (_, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: ClipOval(
                  child: AppNetworkImage(
                    url: entry.posterUrl,
                    width: 28,
                    height: 28,
                    fit: BoxFit.cover,
                    errorWidget: ColoredBox(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Le nom de la saison ouverte et, dessous, son nombre d'épisodes. Il apparaît
/// en fondu quand la bulle a commencé à s'élargir.
class _Label extends StatelessWidget {
  final SeasonBubbleEntry entry;

  /// Le nom entre en fondu et glisse de 8 px quand la bulle est éclairée,
  /// donc après la goutte.
  final bool lit;

  const _Label({required this.entry, required this.lit});

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: lit ? Offset.zero : const Offset(-0.04, 0),
      duration: AppMotion.move(context, AppMotion.emphasis),
      curve: AppMotion.curve,
      child: AnimatedOpacity(
        opacity: lit ? 1 : 0,
        duration: AppMotion.fade(context, AppMotion.emphasis),
        curve: AppMotion.curve,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 16, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: AppType.subhead,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (entry.requested) ...[
                      const Icon(AppIcons.pending,
                          size: 12, color: AppColors.warning),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        entry.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: AppType.caption,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le sablier orange d'une saison demandée, au bord de sa bulle fermée, détouré
/// du fond de la page.
class _RequestedPip extends StatelessWidget {
  const _RequestedPip();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.background,
      ),
      child: SizedBox.square(
        dimension: 18,
        child: Icon(AppIcons.pending, size: 13, color: AppColors.warning),
      ),
    );
  }
}

/// Le nuage barré d'une saison absente et pas demandée, même emplacement que
/// [_RequestedPip] : les deux badges sont mutuellement exclusifs.
class _MissingPip extends StatelessWidget {
  const _MissingPip();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.background,
      ),
      child: SizedBox.square(
        dimension: 18,
        child: Icon(AppIcons.cloudOff, size: 13, color: AppColors.textMuted),
      ),
    );
  }
}
