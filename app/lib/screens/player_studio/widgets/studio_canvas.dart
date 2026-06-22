import 'package:flutter/material.dart';
import '../hooks/use_studio_controller.dart';
import 'draggable_control.dart';

/// The 16:9 editing surface. Renders a dummy poster background, a snap grid,
/// and all the draggable controls positioned via relative percentages.
class StudioCanvas extends StatelessWidget {
  final StudioController controller;

  const StudioCanvas({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
            return AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final selected = controller.selectedId;
                final selConfig = controller.selectedConfig;

                return Stack(
                  children: [
                    const _DummyPoster(),

                    // Snap grid (subtle when dragging, barely visible otherwise)
                    IgnorePointer(
                      child: _GridOverlay(
                        hSegments: controller.horizontalSegments,
                        vSegments: controller.verticalSegments,
                        dim: !controller.isDragging,
                      ),
                    ),

                    // Tap empty space to deselect.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => controller.select(null),
                      ),
                    ),

                    for (final placed in controller.draft.controls)
                      DraggableControl(
                        placed: placed,
                        canvasSize: canvasSize,
                        selected: selected == placed.id,
                        onTap: () => controller.select(placed.id),
                        onDrag: (delta) =>
                            controller.dragBy(placed.id, delta, canvasSize),
                        onDragEnd: controller.endDrag,
                      ),

                    // Real-time coordinate tooltip
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
                            color: const Color(0xFF007AFF),
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
                size: 48, color: Colors.white.withOpacity(0.15)),
            const SizedBox(height: 8),
            Text(
              'APERÇU',
              style: TextStyle(
                color: Colors.white.withOpacity(0.15),
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

/// Subtle dotted grid overlay that brightens while the user is dragging.
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

        // Vertical lines
        for (var i = 1; i < hSegments; i++) {
          final x = w * (i / hSegments);
          children.add(
            Positioned(
              left: x - 0.5,
              top: 0,
              bottom: 0,
              child: Container(
                width: 1,
                color: Colors.white.withOpacity(opacity),
              ),
            ),
          );
        }

        // Horizontal lines
        for (var i = 1; i < vSegments; i++) {
          final y = h * (i / vSegments);
          children.add(
            Positioned(
              top: y - 0.5,
              left: 0,
              right: 0,
              child: Container(
                height: 1,
                color: Colors.white.withOpacity(opacity),
              ),
            ),
          );
        }

        return Stack(children: children);
      },
    );
  }
}
