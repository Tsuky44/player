import 'package:flutter/material.dart';

import '../../../../l10n/tr.dart';
import '../../../../tv/tv_focus.dart';
import '../../../../tv/tv_focus_rows.dart';
import '../../playback/skip_segments.dart';
import 'onyx_chrome_theme.dart';

/// Skip-intro affordance: a bordered pill above the controls, shown
/// only while an intro — or the recap before it — is playing.
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

  /// Ce que la pastille saute : seul son libellé en dépend.
  final SkipSegment segment;

  const OnyxSkipIntroButton({
    super.key,
    required this.onPressed,
    required this.metrics,
    this.autoSkipIn,
    this.segment = SkipSegment.intro,
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
                  switch (widget.segment) {
                    SkipSegment.recap => tr('Passer le récap'),
                    SkipSegment.intro => tr('Passer l’intro'),
                  },
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

/// La pastille à sa place : à droite, juste au-dessus de la barre du bas, la
/// même sur tous les chromes.
class OnyxSkipIntroSlot extends StatelessWidget {
  final VoidCallback onPressed;
  final OnyxChromeMetrics metrics;
  final Duration? autoSkipIn;
  final SkipSegment segment;

  /// Vrai sur le chrome télé : la pastille forme alors sa propre rangée pour
  /// le D-pad.
  final bool focusRow;

  const OnyxSkipIntroSlot({
    super.key,
    required this.onPressed,
    required this.metrics,
    this.autoSkipIn,
    this.segment = SkipSegment.intro,
    this.focusRow = false,
  });

  @override
  Widget build(BuildContext context) {
    final Widget button = OnyxSkipIntroButton(
      onPressed: onPressed,
      metrics: metrics,
      autoSkipIn: autoSkipIn,
      segment: segment,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(metrics.gutter, 0, metrics.gutter, 14),
      child: Align(
        alignment: Alignment.centerRight,
        child: focusRow ? TvFocusRow(child: button) : button,
      ),
    );
  }
}
