import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../../models/models.dart';
import '../../models/player_layout.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/player_layout_provider.dart';
import '../../navigation/search_route_observer.dart';
import '../../services/api_client.dart';
import 'hooks/use_player_controller.dart';
import 'hooks/use_episode_navigation.dart';
import 'hooks/use_player_media_keys.dart';
import 'widgets/skip_intro_button.dart';
import 'widgets/next_episode_overlay.dart';
import 'widgets/player_hud_overlay.dart';
import 'widgets/modular_controls_layer.dart';
import 'widgets/top_right_controls.dart';
import 'widgets/player_settings_sheet.dart';
import 'widgets/player_settings_anchor.dart';
import 'widgets/player_subtitles_sheet.dart';
import 'widgets/player_episodes_panel.dart';
import 'player_playback_preferences.dart';
import '../../desktop_window.dart';

class PlayerScreen extends StatefulWidget {
  final dynamic media; // Can be Media or HomeMediaItem
  final PlayerPlaybackPreferences? inheritedPreferences;
  final bool autoAdvance;
  final BoxFit? initialVideoFit;
  final int? seasonNumber;

  const PlayerScreen({
    super.key,
    required this.media,
    this.inheritedPreferences,
    this.autoAdvance = false,
    this.initialVideoFit,
    this.seasonNumber,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerController _playerController;
  EpisodeNavigationController? _episodeNav;
  bool _isInitialized = false;
  bool _showControls = true;
  bool _isEpisodeTransition = false;
  Timer? _controlsTimer;
  bool _isDisposing = false;
  bool _progressFlushed = false;
  ApiClient? _apiClient;

  /// How the video is fitted inside the player viewport.
  /// [BoxFit.contain] = original (letterbox possible).
  /// [BoxFit.cover]   = adaptive (fills screen, may crop edges).
  BoxFit _videoFit = BoxFit.contain;

  /// Key attached to the settings button so we can anchor the popup above it.
  final GlobalKey _settingsButtonKey = GlobalKey();

  /// Key attached to the subtitles button so we can anchor the popup above it.
  final GlobalKey _subtitlesButtonKey = GlobalKey();

  /// Key to access VideoState and call update() so fit changes propagate.
  final GlobalKey<VideoState> _videoKey = GlobalKey();

  /// Anchors subtitle lift to the real progress/timeline bar position.
  final GlobalKey _timelineAnchorKey = GlobalKey();

  final FocusNode _keyboardFocusNode = FocusNode();

  static const double _volumeStep = 5.0;

  EdgeInsets? _lastSubtitlePadding;

  // Store the listener so we can properly remove it in dispose
  VoidCallback? _episodeNavListener;
  late final PlayerMediaKeysBinding _mediaKeys;
  int _lastMediaSessionSyncPos = -1;
  bool? _lastMediaSessionPlaying;

  /// Throttles timeline/control rebuilds driven by mpv position ticks (~30/s).
  DateTime? _lastPositionUiRefresh;
  static const _positionUiRefreshInterval = Duration(milliseconds: 250);

  String? _mediaLogoUrl;

  bool _showEpisodesPanel = false;
  bool _episodesPanelLoading = false;
  List<Media> _episodesPanelSeasons = [];
  List<HomeMediaItem> _episodesPanelEpisodes = [];
  int? _episodesPanelSeasonId;
  String _episodesPanelShowTitle = '';

  String get _playerTitle =>
      playerMediaTitle(widget.media, seasonNumber: widget.seasonNumber);

  Future<void> _loadMediaLogo(Media media) async {
    final api = _apiClient;
    if (api == null) return;

    int? detailsId;
    if (media.type == MediaType.movie || media.type == MediaType.show) {
      detailsId = media.id;
    } else if (media.type == MediaType.episode &&
        widget.media is HomeMediaItem) {
      detailsId = (widget.media as HomeMediaItem).showId;
    }
    if (detailsId == null || detailsId <= 0) return;

    try {
      final details = await api.getMediaDetails(detailsId);
      if (!mounted) return;
      setState(() => _mediaLogoUrl = details.logoUrl);
    } catch (_) {}
  }

  int? _seasonNumberFor(dynamic media) {
    if (widget.seasonNumber != null && widget.seasonNumber! > 0) {
      return widget.seasonNumber;
    }
    if (media is HomeMediaItem) {
      return media.media.effectiveSeasonNumber;
    }
    if (media is Media) {
      return media.effectiveSeasonNumber;
    }
    return null;
  }

  Media get _actualMedia {
    if (widget.media is HomeMediaItem) {
      return (widget.media as HomeMediaItem).media;
    }
    return widget.media as Media;
  }

  bool get _isEpisode => _actualMedia.type == MediaType.episode;

  int get _currentEpisodeId => _actualMedia.id;

  int? get _currentSeasonId => _actualMedia.parentId;

  int? get _currentShowId {
    if (widget.media is HomeMediaItem) {
      return (widget.media as HomeMediaItem).showId;
    }
    return null;
  }

  String get _episodesShowTitle {
    if (widget.media is HomeMediaItem) {
      return (widget.media as HomeMediaItem).displayTitle;
    }
    final parts = _playerTitle.split(' – ');
    return parts.isNotEmpty ? parts.first : _playerTitle;
  }

  Future<void> _openEpisodesPanel() async {
    if (!_isEpisode || _apiClient == null) return;
    setState(() {
      _showEpisodesPanel = true;
      _showControls = true;
      _episodesPanelLoading = true;
      _episodesPanelShowTitle = _episodesShowTitle;
      _episodesPanelSeasonId = _currentSeasonId;
      _episodesPanelEpisodes = [];
    });
    _controlsTimer?.cancel();
    await _loadEpisodesPanelData();
  }

  void _closeEpisodesPanel() {
    if (!_showEpisodesPanel) return;
    setState(() => _showEpisodesPanel = false);
    _hideControlsWithDelay();
  }

  Future<void> _loadEpisodesPanelData({int? seasonId}) async {
    final api = _apiClient;
    if (api == null) return;

    final targetSeasonId = seasonId ?? _currentSeasonId;
    if (targetSeasonId == null || targetSeasonId <= 0) {
      if (mounted) setState(() => _episodesPanelLoading = false);
      return;
    }

    try {
      if (_episodesPanelSeasons.isEmpty) {
        final showId = _currentShowId;
        if (showId != null && showId > 0) {
          _episodesPanelSeasons = await api.getShowSeasons(showId);
        }
      }

      final episodes = await api.getSeasonEpisodes(targetSeasonId);
      if (!mounted) return;

      final showTitle = episodes.isNotEmpty &&
              episodes.first.showTitle?.isNotEmpty == true
          ? episodes.first.showTitle!
          : _episodesPanelShowTitle;

      setState(() {
        _episodesPanelEpisodes = episodes;
        _episodesPanelSeasonId = targetSeasonId;
        _episodesPanelShowTitle = showTitle;
        _episodesPanelLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _episodesPanelLoading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _showControls = !widget.autoAdvance;
    _videoFit = widget.initialVideoFit ?? BoxFit.contain;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDesktopCaption.value = false;
      });
    }
    _playerController = PlayerController();
    _mediaKeys = PlayerMediaKeysBinding(
      onPlayPause: _togglePlayPause,
      onRewind: () => _seekRelative(-10),
      onFastForward: _handleMediaFastForward,
      isPlaying: () => _playerController.isPlaying,
    );
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

    int knownDuration = actualMedia.duration;
    if (widget.media is HomeMediaItem) {
      final item = widget.media as HomeMediaItem;
      knownDuration = item.effectiveDuration;
    }

    await _playerController.init(
      media: actualMedia,
      apiClient: apiClient,
      knownDurationSeconds: knownDuration,
      inheritedPreferences: widget.inheritedPreferences,
      onCompleted: _onPlaybackCompleted,
      onPositionChanged: _onPositionChanged,
      onPlayingChanged: () {
        _safeSetState(() {});
        unawaited(_syncMediaSession(force: true));
      },
      onDurationChanged: () {
        if (_isDisposing || !mounted) return;
        setState(() {});
      },
      onQualitySwitchingChanged: () {
        _safeSetState(() {});
      },
      onTracksChanged: () {
        // Background subtitle extraction finished: rebuild so the settings
        // menu reflects the freshly available tracks.
        _safeSetState(() {});
      },
    );

    unawaited(_loadMediaLogo(actualMedia));

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
      unawaited(_episodeNav!.load());
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

  bool _needsPositionUiRefresh() =>
      _showControls || _showEpisodesPanel;

  void _refreshPositionUi({bool force = false}) {
    if (!_needsPositionUiRefresh()) return;

    final now = DateTime.now();
    if (!force &&
        _lastPositionUiRefresh != null &&
        now.difference(_lastPositionUiRefresh!) < _positionUiRefreshInterval) {
      return;
    }
    _lastPositionUiRefresh = now;
    _safeSetState(() {});
  }

  void _onPositionChanged() {
    if (_isDisposing || !mounted) return;
    _episodeNav?.checkPosition(
      _playerController.position.inSeconds,
      mediaDurationSeconds: _playerController.duration.inSeconds,
    );
    unawaited(_syncMediaSession());
    _refreshPositionUi();
  }

  void _scheduleSubtitlePaddingSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSubtitlePadding(context);
    });
  }

  Future<void> _syncMediaSession({bool force = false}) async {
    if (!_isInitialized || _isDisposing) return;

    final positionSeconds = _playerController.position.inSeconds;
    final playing = _playerController.isPlaying;
    if (!force &&
        _lastMediaSessionPlaying == playing &&
        _lastMediaSessionSyncPos >= 0 &&
        (positionSeconds - _lastMediaSessionSyncPos).abs() < 15) {
      return;
    }

    _lastMediaSessionSyncPos = positionSeconds;
    _lastMediaSessionPlaying = playing;

    await _mediaKeys.syncSession(
      title: _playerTitle,
      durationSeconds: _playerController.duration.inSeconds,
      positionSeconds: positionSeconds,
      playing: playing,
    );
  }

  void _onPlaybackCompleted() {
    if (_isDisposing || !mounted) return;
    _safeSetState(() {});
    if (_episodeNav?.nextEpisode != null) {
      _goToNextEpisode();
    } else {
      unawaited(_leavePlayer());
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
    if (widget.media is HomeMediaItem) {
      final item = widget.media as HomeMediaItem;
      if (!item.isFinished) {
        savedPositionSeconds = item.currentPositionSeconds;
      }
    }

    try {
      final progressData = await apiClient.getProgress(actualMedia.id);
      final fromApi = progressData["current_position_seconds"] as int? ?? 0;
      final isFinished = progressData["is_finished"] as bool? ?? false;
      if (isFinished) {
        savedPositionSeconds = 0;
      } else if (fromApi > savedPositionSeconds) {
        savedPositionSeconds = fromApi;
      }
    } catch (e) {
      print("Player: Failed to query progress: $e");
    }

    if (!mounted) return;
    final resumeAt = (!widget.autoAdvance && savedPositionSeconds >= 3)
        ? savedPositionSeconds
        : 0;
    await _startPlayback(resumeAtSeconds: resumeAt);
  }

  Future<void> _startPlayback({int resumeAtSeconds = 0}) async {
    Media actualMedia;
    if (widget.media is HomeMediaItem) {
      actualMedia = (widget.media as HomeMediaItem).media;
    } else {
      actualMedia = widget.media as Media;
    }

    await _playerController.startPlayback(
      mediaId: actualMedia.id,
      apiClient: _apiClient!,
      resumeAtSeconds: resumeAtSeconds,
    );
    if (!mounted) return;
    setState(() => _isInitialized = true);
    _scheduleSubtitlePaddingSync();
    unawaited(_mediaKeys.attach(
      title: _playerTitle,
      durationSeconds: _playerController.duration.inSeconds,
      positionSeconds: _playerController.position.inSeconds,
    ));
    _keyboardFocusNode.requestFocus();
    _hideControlsWithDelay();
  }

  void _handleMediaFastForward() {
    if (_episodeNav?.nextEpisode != null) {
      _goToNextEpisode();
    } else {
      _seekRelative(10);
    }
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _refreshPositionUi(force: true);
      _scheduleSubtitlePaddingSync();
      _hideControlsWithDelay();
    }
  }

  void _handleVideoTap() {
    _keyboardFocusNode.requestFocus();
    final layoutProvider = Provider.of<PlayerLayoutProvider>(context, listen: false);
    if (layoutProvider.useModularLayout &&
        layoutProvider.config.tapToTogglePlayback) {
      _togglePlayPause();
      _showControlsTransient();
      return;
    }
    _toggleControls();
  }

  void _hideControlsWithDelay() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (_isDisposing) return;
      if (!mounted) return;
      if (_showControls && !_playerController.isDraggingSlider && _playerController.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTransient() {
    setState(() => _showControls = true);
    _refreshPositionUi(force: true);
    _scheduleSubtitlePaddingSync();
    _hideControlsWithDelay();
  }

  /// Netflix-style: hide the cursor while controls are hidden during playback.
  bool get _shouldHideCursor =>
      !_showControls &&
      _playerController.isPlaying &&
      !_playerController.isDraggingSlider;

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

  void _adjustVolume(double delta) {
    final player = _playerController.player;
    final next = (player.state.volume + delta).clamp(0.0, 100.0);
    player.setVolume(next);
    _showControlsTransient();
    _safeSetState(() {});
  }

  KeyEventResult _handlePlayerKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isInitialized || _isDisposing) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final mediaResult = _mediaKeys.handleKeyboardEvent(event);
    if (mediaResult != null) return mediaResult;

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.space) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      _togglePlayPause();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekRelative(-10);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      _seekRelative(10);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      _adjustVolume(_volumeStep);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      _adjustVolume(-_volumeStep);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_showEpisodesPanel) {
        _closeEpisodesPanel();
        return KeyEventResult.handled;
      }
      unawaited(_exitFullscreenIfActive());
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _goToNextEpisode() {
    final next = _episodeNav?.nextEpisode;
    if (next == null) return;
    _navigateToEpisode(next);
  }

  void _goToEpisode(HomeMediaItem episode) {
    _navigateToEpisode(episode);
  }

  void _navigateToEpisode(HomeMediaItem next) {
    if (next.media.id == _currentEpisodeId) {
      _closeEpisodesPanel();
      return;
    }

    _closeEpisodesPanel();
    _isEpisodeTransition = true;
    final inheritedPreferences =
        _playerController.exportPreferences();
    final videoFit = _videoFit;

    // Cancel all streams BEFORE navigation
    _playerController.cancelStreams();
    if (_episodeNav != null && _episodeNavListener != null) {
      _episodeNav!.removeListener(_episodeNavListener!);
      _episodeNav!.dispose();
      _episodeNav = null;
      _episodeNavListener = null;
    }

    unawaited(_syncProgressOnExit(popAfter: false));

    // Defer navigation by one frame so pending stream events flush safely
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
          builder: (_) => PlayerScreen(
            media: next,
            inheritedPreferences: inheritedPreferences,
            autoAdvance: true,
            initialVideoFit: videoFit,
            seasonNumber: _seasonNumberFor(next),
          ),
        ),
      );
    });
  }

  Future<void> _syncProgressOnExit({required bool popAfter}) async {
    if (_progressFlushed) {
      if (popAfter && mounted) Navigator.of(context).pop();
      return;
    }
    _progressFlushed = true;
    _controlsTimer?.cancel();

    Media actualMedia;
    HomeMediaItem? sourceItem;
    if (widget.media is HomeMediaItem) {
      sourceItem = widget.media as HomeMediaItem;
      actualMedia = sourceItem.media;
    } else {
      actualMedia = widget.media as Media;
    }

    final posSeconds = _playerController.position.inSeconds;
    var durSeconds = _playerController.duration.inSeconds;
    if (durSeconds <= 0 && widget.media is HomeMediaItem) {
      durSeconds = (widget.media as HomeMediaItem).effectiveDuration;
    } else if (durSeconds <= 0) {
      durSeconds = actualMedia.duration;
    }

    final isFinished =
        durSeconds > 0 && (posSeconds / durSeconds) * 100 >= 90.0;

    HomeProvider? homeProvider;
    if (mounted) {
      homeProvider = Provider.of<HomeProvider>(context, listen: false);
      if (posSeconds > 0) {
        homeProvider.updateContinueWatchingProgress(
          mediaId: actualMedia.id,
          positionSeconds: posSeconds,
          durationSeconds: durSeconds,
          isFinished: isFinished,
          sourceItem: sourceItem,
        );
      }
    }

    if (_apiClient != null) {
      await _playerController.finishPlayback(
        mediaId: actualMedia.id,
        apiClient: _apiClient!,
        isFinished: isFinished,
      );
    }

    homeProvider?.loadHome(silent: true);

    if (popAfter && mounted) Navigator.of(context).pop();
  }

  Future<void> _leavePlayer() => _syncProgressOnExit(popAfter: true);

  @override
  void dispose() {
    unawaited(_mediaKeys.detach());
    _keyboardFocusNode.dispose();
    _isDisposing = true;
    _controlsTimer?.cancel();
    if (!_progressFlushed && _apiClient != null) {
      unawaited(_syncProgressOnExit(popAfter: false));
    }
    if (Platform.isWindows) {
      if (!_isEpisodeTransition) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          showDesktopCaption.value = true;
        });
      }
    }
    if (!_isEpisodeTransition) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
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

  void _syncSubtitlePadding(BuildContext context) {
    if (!mounted || !_isInitialized) return;

    final layoutProvider = Provider.of<PlayerLayoutProvider>(context, listen: false);
    final screenSize = MediaQuery.sizeOf(context);
    final measuredTop = _measureTimelineTop(context);
    final padding = SubtitlePaddingCalculator.resolve(
      controlsVisible: _showControls,
      useModularLayout: layoutProvider.useModularLayout,
      modularConfig: layoutProvider.config,
      screenSize: screenSize,
      measuredTimelineTopDy: measuredTop,
    );

    if (padding == _lastSubtitlePadding) return;
    _lastSubtitlePadding = padding;

    _videoKey.currentState?.setSubtitleViewPadding(
      padding,
      duration: const Duration(milliseconds: 200),
    );

    // Timeline may not be laid out on the first frame after controls appear.
    if (_showControls && measuredTop == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncSubtitlePadding(context);
      });
    }
  }

  double? _measureTimelineTop(BuildContext context) {
    if (!_showControls) return null;

    final box = _timelineAnchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;

    return box.localToGlobal(Offset.zero).dy;
  }

  void _showTrackSettings() {
    final renderBox = _settingsButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final buttonRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
    final screenSize = MediaQuery.sizeOf(context);
    final hasChaptersTab = _episodeNav != null;
    final menuWidth =
        PlayerSettingsAnchor.sheetWidth(hasChaptersTab: hasChaptersTab);
    final menuMaxHeight =
        PlayerSettingsAnchor.sheetMaxHeight(hasChaptersTab: hasChaptersTab);
    final left = PlayerSettingsAnchor.horizontalLeft(
      buttonRect: buttonRect,
      screenSize: screenSize,
      popupWidth: menuWidth,
    );
    final vertical = PlayerSettingsAnchor.verticalPlacement(
      buttonRect: buttonRect,
      screenSize: screenSize,
      popupMaxHeight: menuMaxHeight,
    );

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
                  left: left,
                  bottom: vertical.bottom,
                  top: vertical.top,
                  child: PlayerSettingsSheet(
                    player: _playerController.player,
                    currentFit: _videoFit,
                    onFitChanged: _updateVideoFit,
                    onClose: entry.remove,
                    playerController: _playerController,
                    episodeNav: _episodeNav,
                    onSeekToAbsolute: _playerController.seekToAbsoluteSeconds,
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

  void _showSubtitlesMenu() {
    final renderBox =
        _subtitlesButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final buttonRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
    final screenSize = MediaQuery.sizeOf(context);
    const menuWidth = PlayerSettingsAnchor.subtitlesSheetWidth;
    const menuMaxHeight = PlayerSettingsAnchor.subtitlesSheetMaxHeight;
    final left = PlayerSettingsAnchor.horizontalLeft(
      buttonRect: buttonRect,
      screenSize: screenSize,
      popupWidth: menuWidth,
    );
    final vertical = PlayerSettingsAnchor.verticalPlacement(
      buttonRect: buttonRect,
      screenSize: screenSize,
      popupMaxHeight: menuMaxHeight,
    );

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
                  left: left,
                  bottom: vertical.bottom,
                  top: vertical.top,
                  child: PlayerSubtitlesSheet(
                    player: _playerController.player,
                    playerController: _playerController,
                    onClose: entry.remove,
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

  Future<void> _toggleFullscreen() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final isFullScreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFullScreen);
    }
  }

  Future<void> _exitFullscreenIfActive() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final isFullScreen = await windowManager.isFullScreen();
      if (isFullScreen) {
        await windowManager.setFullScreen(false);
      }
    }
  }

  void _togglePlayPause() {
    _playerController.togglePlayPause();
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
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          await _leavePlayer();
        },
        child: const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator(color: Color(0xFF00A4DC))),
        ),
      );
    }

    final layoutProvider = Provider.of<PlayerLayoutProvider>(context);
    final useModular = layoutProvider.useModularLayout;
    final totalSeconds = _playerController.duration.inSeconds;
    final progressFraction =
        totalSeconds > 0 ? _playerController.position.inSeconds / totalSeconds : 0.0;

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handlePlayerKeyEvent,
      child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _leavePlayer();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        cursor: _shouldHideCursor ? SystemMouseCursors.none : MouseCursor.defer,
        onHover: (event) {
          _showControlsTransient();
          _episodeNav?.onMouseMove();
        },
        child: GestureDetector(
          onTap: _handleVideoTap,
          child: Stack(
            children: [
              RepaintBoundary(
                child: SizedBox.expand(
                  child: Video(
                    key: _videoKey,
                    controller: _playerController.videoController,
                    controls: null,
                    fit: _videoFit,
                    aspectRatio: _playerController.videoAspectRatio,
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
                        onTap: _handleVideoTap,
                      ),
                    ),
                    Expanded(
                      flex: 4,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _handleVideoTap,
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onDoubleTap: () => _seekRelative(10),
                        onTap: _handleVideoTap,
                      ),
                    ),
                  ],
                ),
              ),
              if (useModular) ...[
                ModularControlsLayer(
                  config: layoutProvider.config,
                  visible: _showControls,
                  timelineAnchorKey: _timelineAnchorKey,
                  isPlaying: _playerController.isPlaying,
                  progress: progressFraction,
                  duration: _playerController.duration,
                  currentSeconds: _playerController.position.inSeconds,
                  onPlayPause: _togglePlayPause,
                  onRewind: () => _seekRelative(-10),
                  onForward: () => _seekRelative(10),
                  onSkipNext: (_episodeNav?.nextEpisode != null)
                      ? _goToNextEpisode
                      : null,
                  onSeekFraction: _seekToFraction,
                  onToggleFullscreen: _toggleFullscreen,
                  mediaTitle: _playerTitle,
                  mediaLogoUrl: _mediaLogoUrl,
                  volume: _playerController.player.state.volume,
                  onVolumeChanged: (v) => _playerController.player.setVolume(v),
                  onBack: _leavePlayer,
                  onOpenSettings: _showTrackSettings,
                  onToggleSubtitles: _showSubtitlesMenu,
                  onOpenUpNext: _isEpisode ? _openEpisodesPanel : null,
                  settingsButtonKey: _settingsButtonKey,
                  subtitlesButtonKey: _subtitlesButtonKey,
                ),
              ] else
                PlayerHUDOverlay(
                  visible: _showControls,
                  timelineAnchorKey: _timelineAnchorKey,
                  player: _playerController.player,
                  media: widget.media,
                  mediaTitle: _playerTitle,
                  isPlaying: _playerController.isPlaying,
                  onPlayPause: _togglePlayPause,
                  position: _playerController.position,
                  duration: _playerController.duration,
                  isDraggingSlider: _playerController.isDraggingSlider,
                  dragValue: _playerController.dragValue,
                  onToggleControls: _toggleControls,
                  onHideControlsWithDelay: _hideControlsWithDelay,
                  onSeekRelative: _seekRelative,
                  onBack: _leavePlayer,
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
                  playerController: _playerController,
                  episodeNav: _episodeNav,
                  onSeekToAbsolute: _playerController.seekToAbsoluteSeconds,
                ),
              // Overlays must be AFTER HUD in Stack to render on top
              if (_episodeNav?.showSkipIntro ?? false)
                SkipIntroButton(
                  onSkip: () async {
                    final end = _episodeNav!.introSkipTarget;
                    await _playerController.seekToAbsoluteSeconds(end);
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
              if (_showEpisodesPanel && _isEpisode)
                PlayerEpisodesPanel(
                  showTitle: _episodesPanelShowTitle,
                  currentEpisodeId: _currentEpisodeId,
                  seasons: _episodesPanelSeasons,
                  selectedSeasonId:
                      _episodesPanelSeasonId ?? _currentSeasonId ?? 0,
                  onSeasonChanged: (seasonId) {
                    setState(() {
                      _episodesPanelLoading = true;
                      _episodesPanelEpisodes = [];
                    });
                    unawaited(_loadEpisodesPanelData(seasonId: seasonId));
                  },
                  episodes: _episodesPanelEpisodes,
                  isLoading: _episodesPanelLoading,
                  onClose: _closeEpisodesPanel,
                  onEpisodeSelected: _goToEpisode,
                ),
              if (_playerController.isSwitchingQuality)
                Positioned.fill(
                  child: AbsorbPointer(
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
                ),
            ],
          ),
        ),
      ),
      ),
      ),
    );
  }
}
