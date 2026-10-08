import 'package:flutter/material.dart';

import '../../../../l10n/tr.dart';
import '../../../../theme/app_colors.dart';
import '../../../../tv/tv_focus.dart';
import '../../../../widgets/global/app_slider.dart';
import '../../../../widgets/global/optimistic_volume.dart';
import 'onyx_chrome_theme.dart';

// Les boutons du Chrome Onyx, sortis d'onyx_controls_layer.dart (ADR-0052).

/// Flat Chrome Onyx icon button, reachable three ways: pointer, finger, and D-pad.
///
/// The remote is the reason this is wrapped in a [TvFocusable] rather than
/// left as a bare [GestureDetector]. Nothing in this chrome used to request
/// focus, so on a television the only focusable widget in it was the volume
/// slider — the remote landed there and had nowhere else to go.
class OnyxIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final OnyxChromeMetrics metrics;

  /// Overrides [OnyxChromeMetrics.iconSize] (play/pause is larger).
  final double? size;

  /// Anchor for popups that open above this button.
  final GlobalKey? buttonKey;

  /// Supplied for the one button the remote is sent to on entry.
  final FocusNode? focusNode;

  /// Television treatment: the button under the remote is filled with the
  /// accent, which reads from across a room where a brighter icon does not.
  final bool isTv;

  /// Television only: a translucent disc even at rest, for the one button the
  /// transport is built around.
  final bool prominent;

  const OnyxIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.metrics,
    this.size,
    this.buttonKey,
    this.focusNode,
    this.isTv = false,
    this.prominent = false,
  });

  @override
  State<OnyxIconButton> createState() => _OnyxIconButtonState();
}

class _OnyxIconButtonState extends State<OnyxIconButton> {
  bool _hovered = false;

  /// Owned when the chrome does not hand one in. The highlight is read from
  /// the node itself rather than from a flag kept in step with focus
  /// callbacks: a callback reports a *change*, and a node that arrives already
  /// focused, or moves between buttons, never produces one — which is how a
  /// button could hold the remote without lighting up.
  FocusNode? _ownedNode;

  FocusNode get _node =>
      widget.focusNode ?? (_ownedNode ??= FocusNode(debugLabel: 'onyx-button'));

  @override
  void dispose() {
    _ownedNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    final iconSize = widget.size ?? m.iconSize;
    // The box grows with an oversized icon so play/pause is not clipped.
    final box = iconSize > m.iconSize ? iconSize + 18 : m.hitSize;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: TvFocusable(
        focusNode: _node,
        onSelect: widget.onPressed,
        // A circle, so the ring hugs a round icon instead of boxing it.
        borderRadius: BorderRadius.circular(box / 2),
        // The television fill replaces the ring.
        showRing: !widget.isTv,
        // Slightly more than the app's cards get: an icon is a much smaller
        // thing to spot from a sofa, and the box has enough padding around it
        // that growing it never reaches its neighbour.
        focusScale: widget.isTv ? 1.15 : 1.12,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            key: widget.buttonKey,
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: ListenableBuilder(
              listenable: _node,
              builder: (context, _) {
                final focused = _node.hasFocus;
                final active = _hovered || focused;
                final filled = widget.isTv && focused;
                final Color? disc = filled
                    ? AppColors.accent
                    : widget.prominent
                        ? Colors.white.withValues(alpha: 0.16)
                        : null;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  width: box,
                  height: box,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: disc ?? Colors.transparent,
                    boxShadow: filled
                        ? [
                            BoxShadow(
                              color: AppColors.accent.withValues(alpha: 0.45),
                              blurRadius: 18,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    widget.icon,
                    size: iconSize,
                    color: active
                        ? OnyxChromeTheme.iconActive
                        : OnyxChromeTheme.icon,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Mute toggle plus an always-visible slider.
///
/// Muting has to remember where the volume was: setting it to 0 and back to a
/// hardcoded default would quietly change the user's level.
class OnyxVolumeControl extends StatefulWidget {
  final double volume;
  final ValueChanged<double> onChanged;
  final OnyxChromeMetrics metrics;

  /// False on narrow chromes, where only the mute button is shown.
  final bool showSlider;

  const OnyxVolumeControl({
    super.key,
    required this.volume,
    required this.onChanged,
    required this.metrics,
    required this.showSlider,
  });

  @override
  State<OnyxVolumeControl> createState() => _OnyxVolumeControlState();
}

class _OnyxVolumeControlState extends State<OnyxVolumeControl> {
  double _lastAudible = 100;
  final OptimisticVolume _shown = OptimisticVolume();

  IconData _icon(double volume) {
    if (volume <= 0) return Icons.volume_off_rounded;
    if (volume < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  void _setVolume(double v) {
    setState(() => _shown.request(v));
    widget.onChanged(v);
  }

  void _toggleMute(double volume) {
    if (volume > 0) {
      _lastAudible = volume;
      _setVolume(0);
    } else {
      _setVolume(_lastAudible <= 0 ? 100 : _lastAudible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metrics;
    final volume = _shown.resolve(widget.volume);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OnyxIconButton(
          icon: _icon(volume),
          tooltip: volume <= 0 ? tr('Rétablir le son') : tr('Couper le son'),
          metrics: m,
          onPressed: () => _toggleMute(volume),
        ),
        if (widget.showSlider)
          SizedBox(
            width: m.isCompact ? 90 : 130,
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 3,
                activeTrackColor: OnyxChromeTheme.progressPlayed,
                inactiveTrackColor: OnyxChromeTheme.progressTrack,
                thumbColor: OnyxChromeTheme.progressPlayed,
                overlayColor: Colors.white24,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: AppSlider(
                value: volume,
                max: 100,
                semanticLabel: tr('Volume'),
                onChanged: (v) {
                  if (v > 0) _lastAudible = v;
                  _setVolume(v);
                },
              ),
            ),
          ),
      ],
    );
  }
}
