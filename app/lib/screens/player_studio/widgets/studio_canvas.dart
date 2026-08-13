import 'package:flutter/material.dart';
import '../hooks/use_studio_controller.dart';
import '../utils/alignment_guides.dart';
import 'control_context_menu.dart';
import 'draggable_control.dart';

/// The 16:9 editing surface. Renders a dummy poster background, a snap grid,
/// and all the draggable controls positioned via relative percentages.
///
/// Fits itself inside the available space (important on phone portrait).
class StudioCanvas extends StatefulWidget {
  final StudioController controller;
  final VoidCallback? onOpenFullControlEditor;

  const StudioCanvas({
    super.key,
    required this.controller,
    this.onOpenFullControlEditor,
  });

  @override
  State<StudioCanvas> createState() => _StudioCanvasState();
}

class _StudioCanvasState extends State<StudioCanvas> {
  final _stackKey = GlobalKey();
  final _controlKeys = <String, GlobalKey>{};
  String? _contextMenuControlId;
  Offset? _contextMenuPosition;

  GlobalKey _keyFor(String id) => _controlKeys.putIfAbsent(id, GlobalKey.new);

  void _closeContextMenu() {
    if (_contextMenuControlId == null) return;
    setState(() {
      _contextMenuControlId = null;
      _contextMenuPosition = null;
    });
  }

  void _openContextMenu(String controlId, Offset globalPosition) {
    final canvasBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final local = canvasBox?.globalToLocal(globalPosition) ??
        globalPosition - Offset.zero;

    widget.controller.select(controlId);
    setState(() {
      _contextMenuControlId = controlId;
      _contextMenuPosition = local;
    });
  }

  void _moveContextMenu(Offset delta, Size canvasSize) {
    if (_contextMenuPosition == null) return;
    setState(() {
      _contextMenuPosition = _clampMenuPosition(
        _contextMenuPosition! + delta,
        canvasSize,
      );
    });
  }

  Offset _clampMenuPosition(Offset position, Size canvasSize) {
    const menuWidth = 268.0;
    const menuHeight = 320.0;
    return Offset(
      position.dx.clamp(8.0, (canvasSize.width - menuWidth - 8.0).clamp(8.0, canvasSize.width)),
      position.dy.clamp(8.0, (canvasSize.height - menuHeight - 8.0).clamp(8.0, canvasSize.height)),
    );
  }

  Map<String, Rect> _measureControlRects() {
    final canvasBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (canvasBox == null) return const {};

    final result = <String, Rect>{};
    for (final placed in widget.controller.draft.controls) {
      final key = _controlKeys[placed.id];
      final box = key?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final topLeft = box.localToGlobal(Offset.zero, ancestor: canvasBox);
      result[placed.id] = topLeft & box.size;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return LayoutBuilder(
      builder: (context, outer) {
        final maxW = outer.maxWidth.isFinite && outer.maxWidth > 0
            ? outer.maxWidth
            : 640.0;
        final maxH = outer.maxHeight.isFinite && outer.maxHeight > 0
            ? outer.maxHeight
            : maxW * 9 / 16;
        var width = maxW;
        var height = width * 9 / 16;
        if (height > maxH) {
          height = maxH;
          width = height * 16 / 9;
        }

        return Align(
          alignment: Alignment.center,
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final canvasSize =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  return AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) {
                      final selected = controller.selectedId;
                      final selConfig = controller.selectedConfig;

                      return Stack(
                        key: _stackKey,
                        children: [
                          const _DummyPoster(),

                          IgnorePointer(
                            child: _GridOverlay(
                              hSegments: controller.horizontalSegments,
                              vSegments: controller.verticalSegments,
                              dim: !controller.isDragging,
                            ),
                          ),

                          if (controller.isDragging &&
                              controller.activeGuides.isNotEmpty)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: _AlignmentGuidesOverlay(
                                  guides: controller.activeGuides,
                                ),
                              ),
                            ),

                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () {
                                controller.select(null);
                                _closeContextMenu();
                              },
                            ),
                          ),

                          for (final placed in controller.draft.controls)
                            DraggableControl(
                              key: ValueKey(placed.id),
                              boundsKey: _keyFor(placed.id),
                              placed: placed,
                              canvasSize: canvasSize,
                              selected: selected == placed.id,
                              isDragging: controller.isDragging &&
                                  selected == placed.id,
                              onSelect: () {
                                controller.select(placed.id);
                                _closeContextMenu();
                              },
                              onSecondaryTapDown: (details) => _openContextMenu(
                                placed.id,
                                details.globalPosition,
                              ),
                              onDrag: (delta) => controller.dragBy(
                                placed.id,
                                delta,
                                canvasSize,
                                measuredRects: _measureControlRects(),
                              ),
                              onDragEnd: controller.endDrag,
                              blurSigma: controller.draft.blurIntensity,
                              glassOpacity: controller.draft.glassOpacity,
                              liquidGlass: controller.draft.liquidGlass,
                              skin: controller.draft.skin,
                              flatAccentColor: controller.draft.flatAccentColor,
                              flatElevation: controller.draft.flatElevation,
                              neumorphicIntensity:
                                  controller.draft.neumorphicIntensity,
                            ),

                          if (_contextMenuControlId != null &&
                              _contextMenuPosition != null)
                            Builder(
                              builder: (context) {
                                final placed = controller.draft
                                    .byId(_contextMenuControlId!);
                                if (placed == null) {
                                  return const SizedBox.shrink();
                                }
                                final pos = _clampMenuPosition(
                                  _contextMenuPosition!,
                                  canvasSize,
                                );
                                return Positioned(
                                  left: pos.dx,
                                  top: pos.dy,
                                  child: ControlContextMenu(
                                    placed: placed,
                                    controller: controller,
                                    onClose: _closeContextMenu,
                                    onDragDelta: (delta) =>
                                        _moveContextMenu(delta, canvasSize),
                                    onOpenFullEditor:
                                        widget.onOpenFullControlEditor == null
                                            ? null
                                            : () {
                                                _closeContextMenu();
                                                widget
                                                    .onOpenFullControlEditor!();
                                              },
                                  ),
                                );
                              },
                            ),

                          if (selConfig != null && controller.isDragging)
                            Positioned(
                              bottom: 8,
                              right: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0A84FF),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'X: ${(selConfig.xPercentage * 100).round()}%  '
                                  'Y: ${(selConfig.yPercentage * 100).round()}%',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DummyPoster extends StatelessWidget {
  const _DummyPoster();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B2735), Color(0xFF090A0F)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_creation_outlined,
                size: 48, color: Colors.white.withValues(alpha: 0.15)),
            const SizedBox(height: 8),
            Text(
              'APERÇU',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.15),
                fontSize: 14,
                letterSpacing: 4,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridOverlay extends StatelessWidget {
  final int hSegments;
  final int vSegments;
  final bool dim;

  const _GridOverlay({
    required this.hSegments,
    required this.vSegments,
    required this.dim,
  });

  @override
  Widget build(BuildContext context) {
    final opacity = dim ? 0.06 : 0.18;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final children = <Widget>[];

        for (var i = 1; i < hSegments; i++) {
          final x = w * (i / hSegments);
          children.add(
            Positioned(
              left: x - 0.5,
              top: 0,
              bottom: 0,
              child: Container(
                width: 1,
                color: Colors.white.withValues(alpha: opacity),
              ),
            ),
          );
        }

        for (var i = 1; i < vSegments; i++) {
          final y = h * (i / vSegments);
          children.add(
            Positioned(
              top: y - 0.5,
              left: 0,
              right: 0,
              child: Container(
                height: 1,
                color: Colors.white.withValues(alpha: opacity),
              ),
            ),
          );
        }

        return Stack(children: children);
      },
    );
  }
}

class _AlignmentGuidesOverlay extends StatelessWidget {
  final List<StudioAlignmentGuide> guides;

  const _AlignmentGuidesOverlay({required this.guides});

  static const _guideColor = Color(0xFFFF2D55);

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final guide in guides)
          if (guide.isVertical)
            Positioned(
              left: guide.positionPx - 0.5,
              top: 0,
              bottom: 0,
              child: Container(width: 1, color: _guideColor),
            )
          else
            Positioned(
              top: guide.positionPx - 0.5,
              left: 0,
              right: 0,
              child: Container(height: 1, color: _guideColor),
            ),
      ],
    );
  }
}
