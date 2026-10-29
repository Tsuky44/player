import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../widgets/global/app_network_image.dart';
import '../../../l10n/tr.dart';
import 'request_season_panel.dart';

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
/// La goutte liquide d'OnyxHub (filtre de fusion SVG) n'est pas portée : elle
/// redessinerait toute la ligne à chaque image, ce que les TV ne tiennent pas
/// (ADR-0086). La bulle se gonfle et la lumière suit, sans la goutte.
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
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _bubbleKeys = {};

  /// Abscisse, dans le cadre du panneau, du centre de la bulle ouverte : la
  /// lumière s'y pose. Une notification plutôt qu'un `setState` : seule la
  /// lumière se redessine quand la bulle bouge.
  final _beamX = ValueNotifier<double?>(null);

  /// Tourne le temps que les bulles changent de largeur, pour que la lumière
  /// suive la bulle ouverte au lieu d'attendre qu'elle ait fini de bouger.
  late final AnimationController _follow;

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
    if (previous != null && previous != number) {
      _direction = number > previous ? 1 : -1;
    }
    setState(() => _selected = previous == number ? null : number);
    if (_selected == null) return;
    _follow.duration = AppMotion.move(context, AppMotion.emphasis);
    _follow.forward(from: 0);
    _measureAfterFrame();
  }

  void _followStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
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
    final selected =
        sorted.where((s) => s.number == _selected).firstOrNull;
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
          child: Row(
            children: [
              for (final season in sorted) ...[
                _SeasonBubble(
                  key: _bubbleKeys.putIfAbsent(season.number, GlobalKey.new),
                  season: season,
                  selected: _selected == season.number,
                  onTap: () => _select(season.number),
                ),
                if (season != sorted.last) const SizedBox(width: _bubbleGap),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        AnimatedSize(
          duration: AppMotion.move(context, AppMotion.emphasis),
          curve: AppMotion.curve,
          alignment: Alignment.topCenter,
          child: selected == null
              ? const SizedBox(width: double.infinity)
              : _SeasonFrame(
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

/// Le cadre de verre du panneau, et la lumière posée sur son bord haut, sous
/// la bulle ouverte. Changer de saison glisse l'ancienne liste hors du cadre
/// pendant que la nouvelle entre du côté de la bulle choisie.
class _SeasonFrame extends StatelessWidget {
  final ValueListenable<double?> beamX;
  final double direction;
  final Widget child;

  const _SeasonFrame({
    super.key,
    required this.beamX,
    required this.direction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(child: _Beam(x: beamX)),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: AnimatedSwitcher(
                  duration: AppMotion.fade(context, AppMotion.emphasis),
                  switchInCurve: AppMotion.curve,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topCenter,
                    children: [...previous, if (current != null) current],
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: Offset(0.04 * direction, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La lumière du panneau : une lueur douce et un filet clair sur le bord haut.
class _Beam extends StatelessWidget {
  final ValueListenable<double?> x;

  const _Beam({required this.x});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: x,
      builder: (_, value, __) {
        if (value == null) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned(
              left: value - 160,
              top: 0,
              width: 320,
              height: 112,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 1.2,
                    colors: [
                      Colors.white.withValues(alpha: 0.13),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: value - 88,
              top: 0,
              width: 176,
              height: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: 0.8),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Une bulle de saison. Fermée, c'est un rond de verre avec son numéro
/// (« SP » pour les épisodes spéciaux) et un point de statut ; ouverte, elle
/// se gonfle en pilule qui montre l'affiche, le nom et le nombre d'épisodes.
class _SeasonBubble extends StatelessWidget {
  final RequestSeason season;
  final bool selected;
  final VoidCallback onTap;

  const _SeasonBubble({
    super.key,
    required this.season,
    required this.selected,
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
        child: AnimatedSize(
          duration: AppMotion.move(context, AppMotion.emphasis),
          curve: AppMotion.curve,
          alignment: Alignment.centerLeft,
          child: Stack(
            children: [
              AnimatedContainer(
                height: _bubbleSize,
                duration: AppMotion.fade(context, AppMotion.emphasis),
                curve: AppMotion.curve,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: selected ? 0.2 : 0.1),
                  borderRadius: radius,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: selected ? 0.32 : 0.14),
                  ),
                  boxShadow: [
                    if (selected)
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
                          padding: EdgeInsets.fromLTRB(
                              6, 0, selected ? 0 : 6, 0),
                          child: _Lead(season: season, selected: selected),
                        ),
                        if (selected)
                          _Label(title: title, detail: detail, status: season.status),
                      ],
                    ),
                  ),
                ),
              ),
              if (!selected)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: IgnorePointer(child: _StatusDot(season.status, ring: true)),
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
  final bool selected;

  const _Lead({required this.season, required this.selected});

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
          AnimatedOpacity(
            opacity: selected ? 0 : 1,
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
          if (selected)
            Padding(
              padding: const EdgeInsets.all(3),
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

  const _Label({
    required this.title,
    required this.detail,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.fade(context, AppMotion.emphasis),
      curve: AppMotion.curve,
      builder: (_, opacity, child) => Opacity(opacity: opacity, child: child),
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
