import 'package:flutter/material.dart';

import '../../../../l10n/tr.dart';
import '../../../../tv/tv_focus.dart';
import 'onyx_chrome_theme.dart';

/// Skip-intro affordance: a bordered pill above the controls, shown
/// only while an intro chapter is playing.
///
/// While [autoSkipIn] is set the pill fills from the left over that time, the
/// way the next-episode pill does: what is on screen says how long is left
/// before the intro skips itself.
class OnyxSkipIntroButton extends StatefulWidget {
  final VoidCallback onPressed;
  final OnyxChromeMetrics metrics;

  /// How long the countdown lasts, or null when nothing is counting down — the
  /// preference is off, or someone touched the player and the skip is theirs
  /// to ask for.
  final Duration? autoSkipIn;

  const OnyxSkipIntroButton({
    super.key,
    required this.onPressed,
    required this.metrics,
    this.autoSkipIn,
  });

  @override
  State<OnyxSkipIntroButton> createState() => _OnyxSkipIntroButtonState();
}

class _OnyxSkipIntroButtonState extends State<OnyxSkipIntroButton>
    with SingleTickerProviderStateMixin {
  // Only draws the time left: the skip itself is the controller's, so a pill
  // that is rebuilt or off screen can neither skip twice nor fail to.
  late final AnimationController _fill = AnimationController(vsync: this);

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(6));

  @override
  void initState() {
    super.initState();
    _syncFill();
  }

  @override
  void didUpdateWidget(OnyxSkipIntroButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoSkipIn != oldWidget.autoSkipIn) _syncFill();
  }

  void _syncFill() {
    final duration = widget.autoSkipIn;
    if (duration == null) {
      _fill.stop();
      _fill.value = 0;
      return;
    }
    _fill.duration = duration;
    _fill.forward(from: 0);
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onSelect: widget.onPressed,
      borderRadius: _radius,
      focusScale: 1.06,
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: _radius,
          side: BorderSide(color: OnyxChromeTheme.icon, width: 1.4),
        ),
        child: InkWell(
          borderRadius: _radius,
          onTap: widget.onPressed,
          child: Stack(
            children: [
              if (widget.autoSkipIn != null)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _fill,
                    builder: (context, child) => FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _fill.value,
                      child: child,
                    ),
                    child: const ColoredBox(
                      color: OnyxChromeTheme.progressBuffered,
                    ),
                  ),
                ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Text(
                  tr('Passer l’intro'),
                  style: TextStyle(
                    color: OnyxChromeTheme.iconActive,
                    fontSize: widget.metrics.skipIntroTextSize,
                    fontWeight: FontWeight.w600,
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
