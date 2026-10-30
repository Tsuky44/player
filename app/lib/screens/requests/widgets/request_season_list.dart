import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../widgets/global/app_network_image.dart';
import '../../../l10n/tr.dart';
import 'request_season_panel.dart';
import 'season_frame.dart';
import 'season_liquid.dart';

/// Diamètre d'une bulle de saison fermée, et marge entre deux bulles.
const _bubbleSize = 48.0;
const _bubbleGap = 12.0;

/// Les saisons d'une série, comme sur OnyxHub (`SeasonList`) : une bulle de
/// verre par saison, rangées par numéro sur une seule ligne, et un panneau
/// d'épisodes dessous. Toucher une bulle la gonfle en pilule (affiche, nom,
/// nombre d'épisodes) et ouvre le panneau de sa saison, une seule à la fois ;
/// retoucher la saison ouverte replie le tout. Une lumière glisse en haut du
/// panneau jusque sous la bulle ouverte.
///
/// Changer de saison lâche une goutte qui file d'une bulle à l'autre
/// (`season_liquid.dart`) : la bulle quittée se retracte, la choisie se gonfle
/// en rebondissant quand la goutte l'atteint, et ne s'éclaire qu'à ce
/// moment. Pas de filtre de fusion comme chez OnyxHub : un seul chemin peint,
/// supprimé en mode léger (ADR-0086).
class RequestSeasonList extends StatefulWidget {
  final int tmdbId;
  final RequestMediaItem showItem;
  final List<RequestSeason> seasons;

  const RequestSeasonList({
    super.key,
    required this.tmdbId,
    required this.showItem,
    required this.seasons,
  });

  @override
  State<RequestSeasonList> createState() => _RequestSeasonListState();
}

class _RequestSeasonListState extends State<RequestSeasonList>
    with SingleTickerProviderStateMixin {
  int? _selected;

  /// Sens du dernier changement de saison (+1 vers la droite) : le contenu
  /// entrant glisse depuis ce côté.
  double _direction = 1;

  final _frameKey = GlobalKey();
  final _rowKey = GlobalKey();
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _bubbleKeys = {};

  /// Abscisse, dans le cadre du panneau, du centre de la bulle ouverte : la
  /// lumière s'y pose. Une notification plutôt qu'un `setState` : seule la
  /// lumière se redessine quand la bulle bouge.
  final _beamX = ValueNotifier<double?>(null);

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

  /// Épisodes déjà chargés par numéro de saison : passer d'une saison à
  /// l'autre ne refait pas d'appel réseau.
  final Map<int, List<RequestEpisode>> _cache = {};

  @override
  void initState() {
    super.initState();
    // Créé ici et non à la première lecture : un `late final` paresseux
    // naîtrait dans `dispose` si aucune saison n'a jamais été ouverte.
    _follow = AnimationController(vsync: this)
      ..addListener(_measureAfterFrame)
      ..addStatusListener(_followStatus);
    _follow.addListener(_lightWhenReached);
    _scroll.addListener(_measureAfterFrame);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _follow.dispose();
    _beamX.dispose();
    super.dispose();
  }

  void _select(int number) {
    final previous = _selected;
    final travelling = previous != null && previous != number;
    if (travelling) _direction = number > previous ? 1 : -1;
    final reduced = AppMotion.reduced(context);
    final next = previous == number ? null : number;

    // La goutte part du centre de la bulle quittée : on le mesure avant que
    // la rangée ne change.
    SeasonDropPlan? plan;
    if (travelling && !reduced) {
      final from = _bubbleRect(previous);
      final to = _bubbleRect(number);
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

    setState(() {
      _from = previous;
      _selected = next;
      _plan = plan;
      // Avec une goutte, la bulle choisie attend qu'elle l'atteigne.
      _lit = plan == null ? next : null;
    });
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
    if (!mounted || _lit == _selected || _selected == null) return;
    if (_follow.value >= _inflateAt) setState(() => _lit = _selected);
  }

  /// Le rectangle d'une bulle dans la rangée, ou nul si elle n'est pas posée.
  Rect? _bubbleRect(int? number) {
    final box = _bubbleKeys[number]?.currentContext?.findRenderObject();
    final row = _rowKey.currentContext?.findRenderObject();
    if (box is! RenderBox || row is! RenderBox) return null;
    if (!box.attached || !row.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: row) & box.size;
  }

  void _followStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_plan != null || _lit != _selected) {
      setState(() {
        _plan = null;
        _lit = _selected;
      });
    }
    // La bulle a pris sa largeur : c'est maintenant qu'on sait si elle dépasse.
    final bubble = _bubbleKeys[_selected]?.currentContext;
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureBeam());
  }

  void _measureBeam() {
    if (!mounted || _selected == null) return;
    final bubble = _bubbleKeys[_selected]?.currentContext?.findRenderObject();
    final frame = _frameKey.currentContext?.findRenderObject();
    if (bubble is! RenderBox ||
        frame is! RenderBox ||
        !bubble.attached ||
        !frame.attached) {
      return;
    }
    final center = bubble.localToGlobal(bubble.size.center(Offset.zero));
    final x = frame.globalToLocal(center).dx;
    if (_beamX.value == null || (_beamX.value! - x).abs() >= 0.5) {
      _beamX.value = x;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.seasons]
      ..sort((a, b) => a.number.compareTo(b.number));
    final selected = sorted.where((s) => s.number == _selected).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Saisons'),
          style: TextStyle(
            fontSize: AppType.title2,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
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
                  for (final season in sorted) ...[
                    _SeasonBubble(
                      key:
                          _bubbleKeys.putIfAbsent(season.number, GlobalKey.new),
                      season: season,
                      selected: _selected == season.number,
                      lit: _lit == season.number,
                      duration: Duration(milliseconds: (_span * 1000).round()),
                      curve: _selected == season.number ? _grow : _shrink,
                      onTap: () => _select(season.number),
                    ),
                    if (season != sorted.last)
                      const SizedBox(width: _bubbleGap),
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
                            final rect = _bubbleRect(_selected);
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
        const SizedBox(height: 4),
        _SizeTween(
          duration: AppMotion.emphasis,
          curve: AppMotion.curve,
          alignment: Alignment.topCenter,
          child: selected == null
              ? const SizedBox(width: double.infinity)
              : SeasonFrame(
                  key: _frameKey,
                  beamX: _beamX,
                  direction: _direction,
                  child: RequestSeasonPanel(
                    key: ValueKey(selected.number),
                    tmdbId: widget.tmdbId,
                    showItem: widget.showItem,
                    season: selected,
                    cache: _cache,
                  ),
                ),
        ),
      ],
    );
  }
}

/// Un `AnimatedSize` qui s'efface quand le mouvement est réduit : à durée
/// nulle, il se mute lui-même pendant sa mise en page.
class _SizeTween extends StatelessWidget {
  final Duration duration;
  final Curve curve;
  final Alignment alignment;
  final Widget child;

  const _SizeTween({
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

/// Une bulle de saison. Fermée, c'est un rond de verre avec son numéro
/// (« SP » pour les épisodes spéciaux) et un point de statut ; ouverte, elle
/// se gonfle en pilule qui montre l'affiche, le nom et le nombre d'épisodes.
class _SeasonBubble extends StatelessWidget {
  final RequestSeason season;

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
    required this.season,
    required this.selected,
    required this.lit,
    required this.duration,
    required this.curve,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final title = seasonTitle(season);
    final count = tr('{0} épisodes', [season.episodeCount]);
    final year = season.year;
    final detail = year == null ? count : '$count · $year';
    const radius = BorderRadius.all(Radius.circular(_bubbleSize / 2));

    return Semantics(
      button: true,
      selected: selected,
      label: '$title, $count',
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: '$title · $count',
        child: _SizeTween(
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
                    customBorder: const StadiumBorder(),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding:
                              EdgeInsets.fromLTRB(6, 0, selected ? 0 : 6, 0),
                          child: _Lead(season: season, lit: lit),
                        ),
                        if (selected)
                          _Label(
                            title: title,
                            detail: detail,
                            status: season.status,
                            lit: lit,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // Le point reste monté : il rentre dans la bulle qui s'ouvre
              // (échelle et fondu) et ressort quand elle se ferme.
              Positioned(
                right: 4,
                bottom: 4,
                child: IgnorePointer(
                  child: AnimatedScale(
                    scale: selected ? 0 : 1,
                    duration: AppMotion.move(context, AppMotion.standard),
                    curve: selected ? Curves.easeIn : Curves.easeOutBack,
                    child: AnimatedOpacity(
                      opacity: selected ? 0 : 1,
                      duration: AppMotion.fade(context, AppMotion.standard),
                      // Saison à demander : un « + » bleu à la place du point.
                      child: season.status.canRequest
                          ? const _RequestPip()
                          : _StatusDot(season.status, ring: true),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le rond de 34 px à gauche de la bulle : le numéro quand elle est fermée,
/// l'affiche de la saison quand elle est ouverte.
class _Lead extends StatelessWidget {
  final RequestSeason season;
  final bool lit;

  const _Lead({required this.season, required this.lit});

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
                season.number == 0 ? 'SP' : '${season.number}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
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
                    url: season.posterUrl,
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
  final String title;
  final String detail;
  final RequestMediaStatus status;

  /// Le nom entre en fondu et glisse de 8 px quand la bulle est éclairée,
  /// donc après la goutte.
  final bool lit;

  const _Label({
    required this.title,
    required this.detail,
    required this.status,
    required this.lit,
  });

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
                  title,
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
                    _StatusDot(status),
                    Flexible(
                      child: Text(
                        detail,
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

/// Le « + » bleu d'une saison pas encore demandée, au bord de sa bulle
/// fermée, détouré du fond de la page comme le point de statut.
class _RequestPip extends StatelessWidget {
  const _RequestPip();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.request,
        border: Border.fromBorderSide(
          BorderSide(color: AppColors.background, width: 2),
        ),
      ),
      child: SizedBox.square(
        dimension: 18,
        child: Icon(AppIcons.add, size: 12, color: Colors.white),
      ),
    );
  }
}

/// Le point de statut d'une saison : vert disponible, moitié ambre
/// partiellement, ambre en attente. Rien tant qu'elle n'est pas demandée.
/// [ring] le détoure du fond de la page quand il se pose sur le bord d'une
/// bulle fermée.
class _StatusDot extends StatelessWidget {
  final RequestMediaStatus status;
  final bool ring;

  const _StatusDot(this.status, {this.ring = false});

  @override
  Widget build(BuildContext context) {
    final decoration = switch (status) {
      RequestMediaStatus.available => const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.success,
        ),
      RequestMediaStatus.partial => BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            stops: const [0.5, 0.5],
            colors: [
              AppColors.warning,
              Colors.white.withValues(alpha: 0.35),
            ],
          ),
        ),
      RequestMediaStatus.pending ||
      RequestMediaStatus.processing =>
        const BoxDecoration(shape: BoxShape.circle, color: AppColors.warning),
      RequestMediaStatus.unknown => null,
    };
    if (decoration == null) return const SizedBox.shrink();
    final dot = DecoratedBox(
      decoration: decoration,
      child: const SizedBox.square(dimension: 7),
    );
    if (ring) {
      return DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.background,
        ),
        child: Padding(padding: const EdgeInsets.all(2), child: dot),
      );
    }
    return Padding(padding: const EdgeInsets.only(right: 6), child: dot);
  }
}
