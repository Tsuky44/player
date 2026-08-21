import 'package:flutter/material.dart';

import '../../../theme/app_motion.dart';

/// The answer to a double-tap: an arc of light over the half of the screen that
/// was tapped, three chevrons running towards the edge, and how far the film
/// just moved.
///
/// A double-tap seek is the one player gesture with no visible cause and a very
/// visible effect — the picture simply jumps. Without an answer the user cannot
/// tell a seek from a stutter, cannot tell which direction it went, and above
/// all cannot tell that a second tap registered. The last of those is what the
/// running total is for: tapping four times means forty seconds, and the number
/// has to say so while the taps are still coming.
///
/// Sits under the chrome and over the picture, and never takes a pointer: the
/// gesture that summons it has to keep working underneath.
class SeekFeedbackOverlay extends StatefulWidget {
  /// Which way the film moved. Decides the side, the arc and the chevrons.
  final bool forward;

  /// The running total, in seconds, always positive.
  final int seconds;

  /// Incremented once per double-tap. A change replays the arc — which is what
  /// makes the fourth tap in a row look different from the third, rather than
  /// leaving a static number on screen.
  final int pulse;

  /// False once the taps have stopped, fading the whole thing out.
  final bool visible;

  const SeekFeedbackOverlay({
    super.key,
    required this.forward,
    required this.seconds,
    required this.pulse,
    required this.visible,
  });

  @override
  State<SeekFeedbackOverlay> createState() => _SeekFeedbackOverlayState();
}

class _SeekFeedbackOverlayState extends State<SeekFeedbackOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.emphasis,
    )..forward();
  }

  @override
  void didUpdateWidget(SeekFeedbackOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // From zero rather than from wherever it had got to: a replay that picks up
    // mid-arc reads as one long smear instead of a second, separate answer.
    if (widget.pulse != oldWidget.pulse) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        // Out slower than in, like the zoom hint: the answer has to be there
        // the instant the second tap lands, and must not sit on the film.
        duration: widget.visible
            ? AppMotion.fade(context, AppMotion.micro)
            : AppMotion.fade(context, AppMotion.emphasis),
        curve: AppMotion.curve,
        child: Align(
          alignment:
              widget.forward ? Alignment.centerRight : Alignment.centerLeft,
          child: FractionallySizedBox(
            // Half the width is what the arc covers, and it is also roughly the
            // half a thumb reaches — the two agreeing is the point.
            widthFactor: 0.5,
            heightFactor: 1,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (!reduced)
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => _Arc(
                      forward: widget.forward,
                      progress: _controller.value,
                    ),
                  ),
                // Pushed out from the middle of the arc towards the edge, so
                // the readout lands over the tap zone that produced it rather
                // than drifting into the play/pause zone next to it.
                Align(
                  alignment: Alignment(widget.forward ? 0.35 : -0.35, 0),
                  child: _Readout(
                    forward: widget.forward,
                    seconds: widget.seconds,
                    progress: reduced
                        ? const AlwaysStoppedAnimation<double>(1)
                        : _controller,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The wash of light behind the chevrons.
///
/// Its flat side is the screen edge and its curved side bows into the middle of
/// the picture — the shape a finger landing on the edge of a phone would make
/// if the glass rippled, which is the whole illusion.
class _Arc extends StatelessWidget {
  final bool forward;

  /// 0 -> 1 across one tap.
  final double progress;

  const _Arc({required this.forward, required this.progress});

  @override
  Widget build(BuildContext context) {
    // In over the first third, out over the rest: the arrival is what the eye
    // needs to catch, the departure only has to not be abrupt.
    final opacity = progress < 0.33
        ? (progress / 0.33) * 0.16
        : (1 - (progress - 0.33) / 0.67) * 0.16;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        // Grows into the picture as it fades, so the light reads as spreading
        // outwards from the tap rather than simply dimming.
        final bulge = w * (0.62 + 0.10 * progress);
        final corner = Radius.elliptical(bulge, h / 2);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: opacity.clamp(0.0, 1.0)),
            borderRadius: forward
                ? BorderRadius.only(topLeft: corner, bottomLeft: corner)
                : BorderRadius.only(topRight: corner, bottomRight: corner),
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

/// The chevrons and the number, the part that survives reduced motion.
class _Readout extends StatelessWidget {
  final bool forward;
  final int seconds;
  final Animation<double> progress;

  const _Readout({
    required this.forward,
    required this.seconds,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: _chevrons()),
        const SizedBox(height: 2),
        Text(
          '$seconds s',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            shadows: [Shadow(color: Color(0x99000000), blurRadius: 10)],
          ),
        ),
      ],
    );
  }

  /// Three chevrons pointing the way the film is going, lighting in order from
  /// the middle of the picture towards the edge.
  List<Widget> _chevrons() {
    final row = [
      for (var i = 0; i < 3; i++)
        AnimatedBuilder(
          animation: progress,
          builder: (context, child) => Opacity(
            opacity: _chevronOpacity(i),
            child: child,
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 26,
            color: Colors.white,
            shadows: [Shadow(color: Color(0x99000000), blurRadius: 10)],
          ),
        ),
    ];
    if (forward) return row;
    // Backward is the same row mirrored: the arrows turn round, and the one
    // that lights first ends up on the inside again rather than at the bezel.
    return [
      for (final chevron in row.reversed)
        Transform.flip(flipX: true, child: chevron),
    ];
  }

  /// Chevron [index] (0 = first to light) against the shared clock.
  ///
  /// They overlap on purpose: the previous chevron is still bright when the
  /// next arrives, which is what makes three separate fades read as one
  /// movement travelling outwards instead of three blinks.
  double _chevronOpacity(int index) {
    final t = ((progress.value - index * 0.18) / 0.42).clamp(0.0, 1.0);
    // Up fast, then held. A chevron that faded back out would leave the row
    // half-lit for most of the animation and unreadable at a glance.
    return 0.35 + 0.65 * t;
  }
}
