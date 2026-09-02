import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../playback/playback_session.dart';

import '../hooks/use_player_controller.dart';
import 'player_settings_anchor.dart';
import 'player_settings_ui.dart';
import 'player_subtitles_picker.dart';

/// Anchored popup for subtitle track selection (same look as settings, subtitles only).
class PlayerSubtitlesSheet extends StatefulWidget {
  final PlaybackSession session;
  final PlayerController playerController;
  final VoidCallback? onClose;

  const PlayerSubtitlesSheet({
    super.key,
    required this.session,
    required this.playerController,
    this.onClose,
  });

  @override
  State<PlayerSubtitlesSheet> createState() => _PlayerSubtitlesSheetState();
}

class _PlayerSubtitlesSheetState extends State<PlayerSubtitlesSheet> {
  StreamSubscription<void>? _tracksSubscription;

  @override
  void initState() {
    super.initState();
    _tracksSubscription = widget.playerController.tracksStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tracksSubscription?.cancel();
    super.dispose();
  }

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlayerSubtitlesShell(
      width: PlayerSettingsAnchor.subtitlesSheetWidth,
      maxHeight: PlayerSettingsAnchor.subtitlesSheetMaxHeight,
      onClose: _close,
      child: PlayerSubtitlesPicker(
        session: widget.session,
        playerController: widget.playerController,
        onSelected: _close,
      ),
    )
        .animate()
        .fadeIn(duration: 220.ms, curve: Curves.easeOut)
        .scaleXY(begin: 0.96, end: 1, duration: 220.ms, curve: Curves.easeOutCubic);
  }
}
