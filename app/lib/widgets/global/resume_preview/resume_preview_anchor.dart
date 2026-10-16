import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_motion.dart';
import '../../../tv/tv_mode.dart';
import 'hover_preview_preference.dart';
import 'resume_preview_panel.dart';
import 'resume_preview_stills.dart';

/// Ouvre l'aperçu d'une carte « Reprendre » quand la souris s'y attarde, à la
/// manière de Netflix : la carte s'agrandit par-dessus la rangée, sans pousser
/// ses voisines ni se faire couper par le bord de la liste.
///
/// Souris seulement : un doigt n'a pas de survol, et un téléviseur garde son
/// focus pour naviguer. Le panneau vit dans l'Overlay de la route, si bien
/// qu'une page poussée par-dessus le recouvre d'elle-même.
class ResumePreviewAnchor extends StatefulWidget {
  const ResumePreviewAnchor({
    super.key,
    required this.item,
    required this.detail,
    required this.onPlay,
    this.onDetails,
    required this.child,
  });

  final HomeMediaItem item;
  final String? detail;
  final VoidCallback onPlay;
  final VoidCallback? onDetails;
  final Widget child;

  /// Le temps pendant lequel la souris doit rester sur la carte. Plus court,
  /// traverser la rangée pour aller ailleurs ouvrait un aperçu à chaque
  /// affiche croisée ; plus long, on croit que rien ne se passe.
  static const Duration dwell = Duration(milliseconds: 700);

  /// Le battement laissé à la souris pour passer de la carte au panneau, qui
  /// la recouvre : sans lui, la sortie de la carte fermerait tout.
  static const Duration leaveGrace = Duration(milliseconds: 120);

  @override
  State<ResumePreviewAnchor> createState() => _ResumePreviewAnchorState();
}

class _ResumePreviewAnchorState extends State<ResumePreviewAnchor>
    with SingleTickerProviderStateMixin {
  static const double _screenMargin = 16;

  /// Hauteur du panneau prise pour le garder dans l'écran. Elle varie avec le
  /// résumé ; cette estimation couvre le cas le plus haut (quatre lignes).
  static const double _estimatedHeight = 400;

  final _portal = OverlayPortalController();
  final _link = LayerLink();
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: AppMotion.emphasis,
  );

  Timer? _openTimer;
  Timer? _closeTimer;

  /// Le panneau est en train de s'effacer ; une souris qui revient le rouvre.
  bool _closing = false;
  ResumePreviewStills? _stills;
  Offset _shift = Offset.zero;
  double _startScale = 1;

  bool get _allowed =>
      HoverPreviewPreference.supported &&
      HoverPreviewPreference.enabled &&
      !TvScope.of(context);

  @override
  void initState() {
    super.initState();
    _reveal.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && _closing) _hideNow();
    });
  }

  @override
  void didUpdateWidget(ResumePreviewAnchor old) {
    super.didUpdateWidget(old);
    // L'accueil s'est rafraîchi et la carte montre autre chose : l'aperçu
    // ouvert parlerait de l'ancien élément.
    if (old.item.media.id != widget.item.media.id ||
        old.item.currentPositionSeconds != widget.item.currentPositionSeconds) {
      _hideNow();
    }
  }

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _reveal.dispose();
    _stills?.dispose();
    super.dispose();
  }

  void _pointerEntered(PointerEnterEvent event) {
    if (event.kind != PointerDeviceKind.mouse || !_allowed) return;
    _stay();
    if (_portal.isShowing) return;
    _openTimer?.cancel();
    _openTimer = Timer(ResumePreviewAnchor.dwell, _open);
  }

  void _pointerLeft(PointerExitEvent _) => _leave();

  void _stay() {
    _closeTimer?.cancel();
    _closeTimer = null;
    if (_closing) {
      _closing = false;
      _reveal.forward();
    }
  }

  void _leave() {
    _openTimer?.cancel();
    _openTimer = null;
    if (!_portal.isShowing) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(ResumePreviewAnchor.leaveGrace, _close);
  }

  void _open() {
    if (!mounted || !_allowed) return;
    final card = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (card == null || overlay == null || !card.hasSize) return;

    // Centré sur l'affiche, puis ramené dans l'écran : une carte au bord de la
    // rangée ouvre son panneau vers l'intérieur.
    const width = ResumePreviewPanel.width;
    final rect = card.localToGlobal(Offset.zero, ancestor: overlay) & card.size;
    final bounds = Offset.zero & overlay.size;
    final left = rect.center.dx - width / 2;
    final top = rect.center.dy - _estimatedHeight / 2;
    final maxLeft =
        math.max(_screenMargin, bounds.width - width - _screenMargin);
    final maxTop = math.max(
        _screenMargin, bounds.height - _estimatedHeight - _screenMargin);
    _shift = Offset(
      left.clamp(_screenMargin, maxLeft) - left,
      top.clamp(_screenMargin, maxTop) - top,
    );
    _startScale = (rect.width / width).clamp(0.3, 1.0);

    _stills?.dispose();
    _stills = ResumePreviewStills.forItem(
        Provider.of<ApiClient>(context, listen: false), widget.item)
      ..start();
    _reveal.duration = AppMotion.fade(context, AppMotion.emphasis);
    _portal.show();
    _reveal.forward(from: 0);
    setState(() {});
  }

  void _close() {
    _closeTimer = null;
    if (!mounted || !_portal.isShowing) return;
    _closing = true;
    _reveal.reverse();
  }

  void _hideNow() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _openTimer = _closeTimer = null;
    _closing = false;
    _reveal.value = 0;
    if (_portal.isShowing) _portal.hide();
    _stills?.dispose();
    _stills = null;
  }

  /// Le panneau s'efface tout de suite : le lancement agrandit l'affiche qu'il
  /// recouvre, et il ne doit pas rester devant.
  void _play() {
    _hideNow();
    widget.onPlay();
  }

  void _details() {
    _hideNow();
    widget.onDetails?.call();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildPanel,
        child: MouseRegion(
          onEnter: _pointerEntered,
          onExit: _pointerLeft,
          child: widget.child,
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final stills = _stills;
    if (stills == null) return const SizedBox.shrink();
    final reduced = AppMotion.reduced(context);
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.center,
        followerAnchor: Alignment.center,
        offset: _shift,
        child: MouseRegion(
          onEnter: (_) => _stay(),
          onExit: (_) => _leave(),
          child: AnimatedBuilder(
            animation: _reveal,
            builder: (context, child) {
              final t = AppMotion.curve.transform(_reveal.value);
              final scale = reduced ? 1.0 : _startScale + (1 - _startScale) * t;
              return Opacity(
                opacity: t,
                child: Transform.scale(scale: scale, child: child),
              );
            },
            child: ResumePreviewPanel(
              item: widget.item,
              stills: stills,
              detail: widget.detail,
              onPlay: _play,
              onDetails: widget.onDetails == null ? null : _details,
            ),
          ),
        ),
      ),
    );
  }
}
