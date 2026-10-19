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
    this.onMenu,
    required this.child,
  });

  final HomeMediaItem item;
  final String? detail;
  final VoidCallback onPlay;
  final VoidCallback? onDetails;

  /// Ouvre le menu de la carte à ce point de l'écran, et se termine quand il
  /// est refermé. Null : pas de « ⋯ » dans l'aperçu non plus.
  final Future<void> Function(Offset globalPosition)? onMenu;
  final Widget child;

  /// Le temps pendant lequel la souris doit rester sur la carte. À 700 ms,
  /// l'aperçu s'ouvrait pendant qu'on allait cliquer « ⋯ » ou le titre ; plus
  /// court encore, traverser la rangée en ouvrait un à chaque affiche croisée.
  static const Duration dwell = Duration(milliseconds: 1200);

  /// Le battement laissé à la souris pour passer de la carte au panneau, qui
  /// la recouvre : sans lui, la sortie de la carte fermerait tout.
  static const Duration leaveGrace = Duration(milliseconds: 120);

  /// Le battement laissé après la fermeture du menu de l'aperçu : la souris
  /// n'est « revenue » sur le panneau qu'une fois le menu retiré de l'écran,
  /// au cadre suivant. Sans lui, l'aperçu se fermerait sous une souris qui ne
  /// l'a jamais quitté.
  static const Duration menuGrace = Duration(milliseconds: 300);

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

  /// La souris est sur la carte, et vise un élément qui suspend le délai.
  bool _inside = false;
  bool _held = false;

  /// Le menu ouvert depuis l'aperçu le recouvre : la souris « sort » alors du
  /// panneau sans l'avoir quitté, et cette sortie-là ne le ferme pas.
  bool _menuOpen = false;
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
    _inside = true;
    _stay();
    _arm();
  }

  void _pointerLeft(PointerExitEvent _) {
    _inside = false;
    _leave();
  }

  /// (Re)part de zéro pour le délai d'ouverture, sauf si la souris vise un
  /// élément qui le suspend ([ResumePreviewHold]).
  void _arm() {
    _openTimer?.cancel();
    _openTimer = null;
    if (_held || _portal.isShowing) return;
    _openTimer = Timer(ResumePreviewAnchor.dwell, _open);
  }

  void _setHeld(bool held) {
    _held = held;
    if (held) {
      _openTimer?.cancel();
      _openTimer = null;
    } else if (_inside) {
      _arm();
    }
  }

  /// Un clic sur la carte (lecture, « ⋯ », clic droit) dit ce que l'on
  /// voulait : l'aperçu ne s'ouvre plus par-dessus.
  void _pointerDown(PointerDownEvent _) {
    _openTimer?.cancel();
    _openTimer = null;
  }

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
    if (!_portal.isShowing || _menuOpen) return;
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

  /// Le menu s'ouvre sous le « ⋯ » de l'aperçu, qui reste derrière lui. Une
  /// fois le menu refermé, l'aperçu suit de nouveau la souris : il reste si
  /// elle est dessus, se ferme sinon.
  Future<void> _menu(Offset globalPosition) async {
    _closeTimer?.cancel();
    _closeTimer = null;
    _menuOpen = true;
    try {
      await widget.onMenu?.call(globalPosition);
    } finally {
      _menuOpen = false;
      if (mounted && _portal.isShowing) {
        _closeTimer = Timer(ResumePreviewAnchor.menuGrace, _close);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildPanel,
        child: Listener(
          onPointerDown: _pointerDown,
          child: MouseRegion(
            onEnter: _pointerEntered,
            onExit: _pointerLeft,
            child: widget.child,
          ),
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
              onMenu: widget.onMenu == null ? null : _menu,
            ),
          ),
        ),
      ),
    );
  }
}

/// Suspend l'ouverture de l'aperçu tant que la souris est sur [child] — le
/// « ⋯ » de la carte, qu'on vise pour cliquer et non pour voir l'aperçu. En
/// le quittant pour le reste de l'affiche, le délai repart de zéro.
class ResumePreviewHold extends StatelessWidget {
  const ResumePreviewHold({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final anchor = context.findAncestorStateOfType<_ResumePreviewAnchorState>();
    if (anchor == null) return child;
    return MouseRegion(
      onEnter: (_) => anchor._setHeld(true),
      onExit: (_) => anchor._setHeld(false),
      child: child,
    );
  }
}
