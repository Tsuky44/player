import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/player_layout_provider.dart';
import '../../services/api_client.dart';
import 'hooks/use_player_controller.dart';
import 'hooks/use_episode_navigation.dart';
import 'widgets/skip_intro_button.dart';
import 'widgets/next_episode_overlay.dart';
import 'widgets/player_hud_overlay.dart';
import 'widgets/modular_controls_layer.dart';
import 'widgets/top_right_controls.dart';
import 'widgets/player_settings_sheet.dart';
import '../../desktop_window.dart';

class PlayerScreen extends StatefulWidget {
  final dynamic media; // Can be Media or HomeMediaItem

  const PlayerScreen({super.key, required this.media});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerController _playerController;
  EpisodeNavigationController? _episodeNav;
  bool _isInitialized = false;
  bool _showControls = true;
  Timer? _controlsTimer;
  bool _isDisposing = false;
  ApiClient? _apiClient;

  /// How the video is fitted inside the player viewport.
  /// [BoxFit.contain] = original (letterbox possible).
  /// [BoxFit.cover]   = adaptive (fills screen, may crop edges).
  BoxFit _videoFit = BoxFit.contain;

  /// Key attached to the settings button so we can anchor the popup above it.
  final GlobalKey _settingsButtonKey = GlobalKey();

  /// Key to access VideoState and call update() so fit changes propagate.
  final GlobalKey<VideoState> _videoKey = GlobalKey();

  // Store the listener so we can properly remove it in dispose
  VoidCallback? _episodeNavListener;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDesktopCaption.value = false;
      });
    }
    _playerController = PlayerController();
    _init();
  }

  Future<void> _init() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final apiClient = authProvider.apiClient;
    _apiClient = apiClient;

    // Extract the actual Media object (handle both Media and HomeMediaItem)
    Media actualMedia;
    if (widget.media is HomeMediaItem) {
      actualMedia = (widget.media as HomeMediaItem).media;
    } else {
      actualMedia = widget.media as Media;
    }

    await _playerController.init(
      media: actualMedia,
      apiClient: apiClient,
      onCompleted: _onPlaybackCompleted,
      onPositionChanged: _onPositionChanged,
      onDurationChanged: () {
        if (_isDisposing || !mounted) return;
        setState(() {});
      },
      onQualitySwitchingChanged: () {
        _safeSetState(() {});
      },
    );

    if (actualMedia.type == MediaType.episode) {
      // Extract timestamps from the media if available (from season episodes list)
      EpisodeTimestamps? initialTimestamps;
      if (widget.media is HomeMediaItem) {
        final homeMediaItem = widget.media as HomeMediaItem;
        initialTimestamps = EpisodeTimestamps(
          introStart: homeMediaItem.introStart,
          introEnd: homeMediaItem.introEnd,
          outroStart: homeMediaItem.outroStart,
          outroEnd: homeMediaItem.outroEnd,
        );
      }

      _episodeNavListener = () {
        _safeSetState(() {});
      };
      _episodeNav = EpisodeNavigationController(
        apiClient: apiClient,
        episodeId: actualMedia.id,
        initialTimestamps: initialTimestamps,
        player: _playerController.player,
        onAutoPlay: _goToNextEpisode,
      );
      _episodeNav!.addListener(_episodeNavListener!);
      await _episodeNav!.load();
    }

    if (mounted) setState(() {});
    _checkAndPromptProgression(apiClient);
  }

  void _safeSetState(VoidCallback fn) {
    if (_isDisposing || !mounted) return;
    try {
      setState(fn);
    } on Object {
      // Widget disposed between check and call
    }
  }

  void _onPositionChanged() {
    if (_isDisposing || !mounted) return;
    _safeSetState(() {});
    _episodeNav?.checkPosition(_playerController.position.inSeconds);
  }

  void _onPlaybackCompleted() {
    if (_isDisposing || !mounted) return;
    _safeSetState(() {});
    if (_episodeNav?.nextEpisode != null) {
      _goToNextEpisode();
    } else {
      _finishAndPop();
      Navigator.of(context).pop();
    }
  }

  Future<void> _checkAndPromptProgression(ApiClient apiClient) async {
    // Extract the actual Media object (handle both Media and HomeMediaItem)
    Media actualMedia;
    if (widget.media is HomeMediaItem) {
      actualMedia = (widget.media as HomeMediaItem).media;
    } else {
      actualMedia = widget.media as Media;
    }

    int savedPositionSeconds = 0;
    try {
      final progressData = await apiClient.getProgress(actualMedia.id);
      savedPositionSeconds = progressData["current_position_seconds"] as int? ?? 0;
      final isFinished = progressData["is_finished"] as bool? ?? false;
      if (isFinished) savedPositionSeconds = 0;
    } catch (e) {
      print("Player: Failed to query progress: $e");
    }

    if (!mounted) return;
    if (savedPositionSeconds > 10) {
      _showResumeDialog(savedPositionSeconds);
    } else {
      _startPlayback();
    }
  }

  void _startPlayback() {
    // Extract the actual Media object (handle both Media and HomeMediaItem)
    Media actualMedia;
    if (widget.media is HomeMediaItem) {
      actualMedia = (widget.media as HomeMediaItem).media;
    } else {
      actualMedia = widget.media as Media;
    }

    _playerController.player.play();
    _playerController.startHeartbeat(
      mediaId: actualMedia.id,
      apiClient: _apiClient!,
    );
    setState(() => _isInitialized = true);
    _hideControlsWithDelay();
  }

  void _showResumeDialog(int resumeSeconds) {
    final minutes = resumeSeconds ~/ 60;
    final seconds = resumeSeconds % 60;
    final timeStr = "$minutes:${seconds.toString().padLeft(2, '0')}";

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text("Reprendre la lecture ?", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text("Voulez-vous reprendre l\u00e0 o\u00f9 vous vous \u00eates arr\u00eat\u00e9 \u00e0 $timeStr ?", style: const TextStyle(color: Color(0xFFCCCCCC))),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _startPlayback();
            },
            child: const Text("Recommencer", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A4DC)),
            onPressed: () async {
              Navigator.of(context).pop();
              await _playerController.player.seek(Duration(seconds: resumeSeconds));
              _startPlayback();
            },
            child: const Text("Reprendre", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _hideControlsWithDelay();
  }

  void _hideControlsWithDelay() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (_isDisposing) return;
      if (!mounted) return;
      if (_showControls && !_playerController.isDraggingSlider && _playerController.player.state.playing) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTransient() {
    setState(() => _showControls = true);
    _hideControlsWithDelay();
  }

  void _seekRelative(int seconds) {
    final currentPos = _playerController.player.state.position;
    final newPos = currentPos + Duration(seconds: seconds);
    final targetPos = newPos.isNegative
        ? Duration.zero
        : newPos > _playerController.duration
            ? _playerController.duration
            : newPos;
    _playerController.player.seek(targetPos);
    _showControlsTransient();
  }

  void _goToNextEpisode() {
    _isDisposing = true;
    final next = _episodeNav?.nextEpisode;
    if (next == null) {
      _isDisposing = false;
      return;
    }

    // Cancel all streams BEFORE navigation
    _playerController.cancelStreams();
    if (_episodeNav != null && _episodeNavListener != null) {
      _episodeNav!.removeListener(_episodeNavListener!);
      _episodeNav!.dispose();
      _episodeNav = null;
      _episodeNavListener = null;
    }

    _finishAndPop();

    // Defer navigation by one frame so pending stream events flush safely
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => PlayerScreen(media: next)),
      );
    });
  }

  Future<void> _finishAndPop() async {
    _controlsTimer?.cancel();
    // Extract the actual Media object (handle both Media and HomeMediaItem)
    Media actualMedia;
    if (widget.media is HomeMediaItem) {
      actualMedia = (widget.media as HomeMediaItem).media;
    } else {
      actualMedia = widget.media as Media;
    }

    await _playerController.finishPlayback(
      mediaId: actualMedia.id,
      apiClient: _apiClient!,
    );
    if (mounted) {
      Provider.of<HomeProvider>(context, listen: false).loadHome(silent: true);
    }
  }

  @override
  void dispose() {
    // Extract the actual Media object (handle both Media and HomeMediaItem)
    Media actualMedia;
    if (widget.media is HomeMediaItem) {
      actualMedia = (widget.media as HomeMediaItem).media;
    } else {
      actualMedia = widget.media as Media;
    }

    _isDisposing = true;
    _controlsTimer?.cancel();
    if (_apiClient != null) {
      _playerController.finishPlayback(
        mediaId: actualMedia.id,
        apiClient: _apiClient!,
      );
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDesktopCaption.value = true;
      });
    }
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (_episodeNav != null && _episodeNavListener != null) {
      _episodeNav!.removeListener(_episodeNavListener!);
    }
    _episodeNav?.dispose();
    _playerController.dispose();
    super.dispose();
  }

  void _updateVideoFit(BoxFit fit) {
    setState(() => _videoFit = fit);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _videoKey.currentState?.update(
        fit: fit,
        aspectRatio: _playerController.videoAspectRatio,
      );
    });
  }

  void _showTrackSettings() {
    final renderBox = _settingsButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final buttonPos = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;
    final screenSize = MediaQuery.of(context).size;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => GestureDetector(
        onTap: () => entry.remove(),
        behavior: HitTestBehavior.translucent,
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: screenSize.width,
            height: screenSize.height,
            child: Stack(
              children: [
                Positioned(
                  left: (buttonPos.dx + buttonSize.width / 2 - 150).clamp(8.0, screenSize.width - 308),
                  bottom: screenSize.height - buttonPos.dy + 8,
                  child: PlayerSettingsSheet(
                    player: _playerController.player,
                    currentFit: _videoFit,
                    onFitChanged: _updateVideoFit,
                    onClose: entry.remove,
                    playerController: _playerController,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
  }

  Media get _actualMedia {
    if (widget.media is HomeMediaItem) {
      return (widget.media as HomeMediaItem).media;
    }
    return widget.media as Media;
  }

  Future<void> _toggleFullscreen() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final isFullScreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFullScreen);
    }
  }

  void _togglePlayPause() {
    final p = _playerController.player;
    if (p.state.playing) {
      p.pause();
    } else {
      p.play();
    }
    _hideControlsWithDelay();
  }

  void _seekToFraction(double fraction) {
    final totalSeconds = _playerController.duration.inSeconds;
    if (totalSeconds <= 0) return;
    _playerController.player
        .seek(Duration(seconds: (fraction * totalSeconds).round()));
    _showControlsTransient();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Color(0xFF00A4DC))),
      );
    }

    final layoutProvider = Provider.of<PlayerLayoutProvider>(context);
    final useModular = layoutProvider.useModularLayout;
    final totalSeconds = _playerController.duration.inSeconds;
    final progressFraction =
        totalSeconds > 0 ? _playerController.position.inSeconds / totalSeconds : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (event) {
          _showControlsTransient();
          _episodeNav?.onMouseMove();
        },
        child: GestureDetector(
          onTap: _toggleControls,
          child: Stack(
            children: [
              SizedBox.expand(
                child: Video(
                  key: _videoKey,
                  controller: _playerController.videoController,
                  controls: null,
                  fit: _videoFit,
                  aspectRatio: _playerController.videoAspectRatio,
                ),
              ),
              if (_playerController.isSwitchingQuality)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF00A4DC),
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onDoubleTap: () => _seekRelative(-10),
                        onTap: _toggleControls,
                      ),
                    ),
                    Expanded(
                      flex: 4,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _toggleControls,
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onDoubleTap: () => _seekRelative(10),
                        onTap: _toggleControls,
                      ),
                    ),
                  ],
                ),
              ),
              if (useModular) ...[
                ModularControlsLayer(
                  config: layoutProvider.config,
                  visible: _showControls,
                  isPlaying: _playerController.player.state.playing,
                  progress: progressFraction,
                  duration: _playerController.duration,
                  currentSeconds: _playerController.position.inSeconds,
                  onPlayPause: _togglePlayPause,
                  onRewind: () => _seekRelative(-10),
                  onForward: () => _seekRelative(10),
                  onSeekFraction: _seekToFraction,
                  onToggleFullscreen: _toggleFullscreen,
                  mediaTitle: _actualMedia.title,
                  volume: _playerController.player.state.volume,
                  onVolumeChanged: (v) => _playerController.player.setVolume(v),
                  onBack: () => Navigator.of(context).pop(),
                  onOpenSettings: _showTrackSettings,
                  settingsButtonKey: _settingsButtonKey,
                ),
              ] else
                PlayerHUDOverlay(
                  visible: _showControls,
                  player: _playerController.player,
                  media: widget.media,
                  position: _playerController.position,
                  duration: _playerController.duration,
                  isDraggingSlider: _playerController.isDraggingSlider,
                  dragValue: _playerController.dragValue,
                  onToggleControls: _toggleControls,
                  onHideControlsWithDelay: _hideControlsWithDelay,
                  onSeekRelative: _seekRelative,
                  onShowTrackSettings: _showTrackSettings,
                  onSliderChangeStart: (value) async {
                    _playerController.isDraggingSlider = true;
                    _playerController.dragValue = value;
                    _safeSetState(() {});
                    try {
                      await (_playerController.player.platform as dynamic).setProperty('hr-seek', 'no');
                    } catch (_) {}
                  },
                  onSliderChanged: (value) {
                    _playerController.dragValue = value;
                    if (_playerController.currentQuality != null) {
                      final relativeSeek = value.toInt() - _playerController.hlsStartOffset;
                      _playerController.player.seek(Duration(seconds: relativeSeek));
                    } else {
                      _playerController.player.seek(Duration(seconds: value.toInt()));
                    }
                    _safeSetState(() {});
                  },
                  onSliderChangeEnd: (value) async {
                    _playerController.isDraggingSlider = false;
                    final targetSeconds = value.toInt();
                    final currentSeconds = _playerController.position.inSeconds;
                    final seekDelta = (targetSeconds - currentSeconds).abs();

                    if (_playerController.currentQuality != null && seekDelta > 10) {
                      // Large seek in HLS mode: reload session at new absolute position
                      await _playerController.reloadHlsAtPosition(targetSeconds);
                    } else if (_playerController.currentQuality != null) {
                      // Small seek in HLS mode: seek relative to HLS stream
                      final relativeSeek = targetSeconds - _playerController.hlsStartOffset;
                      await _playerController.player.seek(Duration(seconds: relativeSeek));
                    } else {
                      await _playerController.player.seek(Duration(seconds: targetSeconds));
                      try {
                        await (_playerController.player.platform as dynamic).setProperty('hr-seek', 'yes');
                      } catch (_) {}
                    }
                    _hideControlsWithDelay();
                  },
                  onNextEpisode: (_episodeNav?.nextEpisode != null) ? _goToNextEpisode : null,
                ),
              if (_showControls && !useModular)
                TopRightControls(
                  player: _playerController.player,
                  currentFit: _videoFit,
                  onFitChanged: _updateVideoFit,
                ),
              // Overlays must be AFTER HUD in Stack to render on top
              if (_episodeNav?.showSkipIntro ?? false)
                SkipIntroButton(
                  onSkip: () {
                    final end = _episodeNav!.introSkipTarget;
                    _playerController.player.seek(Duration(seconds: end));
                    _episodeNav!.skipIntro();
                  },
                ),
              if (_episodeNav?.showNextEpisodeOutro ?? false)
                NextEpisodeOverlay(
                  nextEpisode: _episodeNav!.nextEpisode,
                  autoPlayActive: _episodeNav!.outroAutoPlayActive,
                  frozen: _episodeNav!.outroAutoPlayFrozen,
                  countdownSeconds: _episodeNav!.outroCountdownSeconds,
                  onPlayNext: _goToNextEpisode,
                  onCancel: () => _episodeNav!.cancelAutoPlay(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
