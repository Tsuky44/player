import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../utils/app_platform.dart';
import '../../utils/window_controls.dart';
import '../../models/models.dart';
import '../../models/player_layout.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/player_layout_provider.dart';
import '../../navigation/search_route_observer.dart';
import '../../services/api_client.dart';
import '../../services/media_details_cache.dart';
import '../../utils/poster_url.dart';
import 'hooks/use_player_controller.dart';
import 'hooks/use_episode_navigation.dart';
import 'hooks/use_player_media_keys.dart';
import 'widgets/skip_intro_button.dart';
import 'widgets/next_episode_overlay.dart';
import 'widgets/next_season_overlay.dart';
import 'widgets/player_hud_overlay.dart';
import 'widgets/modular_controls_layer.dart';
import 'widgets/emby/emby_controls_layer.dart';
import 'widgets/emby/emby_settings_menu.dart';
import 'widgets/top_right_controls.dart';
import 'widgets/player_settings_sheet.dart';
import 'widgets/player_settings_anchor.dart';
import 'widgets/player_subtitles_sheet.dart';
import 'widgets/player_info_sheet.dart';
import 'widgets/player_episodes_panel.dart';
import 'player_playback_preferences.dart';
import '../../desktop_window.dart';
import '../../utils/release_tag.dart';
import '../../utils/format.dart';

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

  /// Pack Cinéma — playback rate cycle for studio control.
  double _playbackRate = 1.0;
  static const _playbackRates = [0.75, 1.0, 1.25, 1.5, 2.0];

  /// Key attached to the settings button so we can anchor the popup above it.
  final GlobalKey _settingsButtonKey = GlobalKey();

  /// Key attached to the subtitles button so we can anchor the popup above it.
  final GlobalKey _subtitlesButtonKey = GlobalKey();

  /// Key attached to the media-info button so we can anchor the info card above it.
  final GlobalKey _mediaInfoButtonKey = GlobalKey();

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
  bool _requestingNextSeason = false;
  bool _episodesPanelLoading = false;
  List<Media> _episodesPanelSeasons = [];
  List<HomeMediaItem> _episodesPanelEpisodes = [];
  int? _episodesPanelSeasonId;
  String _episodesPanelShowTitle = '';

  /// The episode before this one inside the same season, when there is one.
  ///
  /// The server only answers "what comes next", so this is resolved from the
  /// season listing instead — the same call the episode panel makes.
  HomeMediaItem? _previousEpisode;

  String get _playerTitle =>
      playerMediaTitle(widget.media, seasonNumber: widget.seasonNumber);

  Future<void> _loadMediaLogo(Media media) async {
    final api = _apiClient;
    if (api == null) return;

    int? detailsId;
    if (media.type == MediaType.movie || media.type == MediaType.show) {
      detailsId = media.id;
    } else if (media.type == MediaType.episode) {
      // The logo belongs to the show, so an episode has to resolve its parent.
      // showId is only present when the player was opened from a home row;
      // parentId covers the episode-list route, which otherwise got no logo.
      if (widget.media is HomeMediaItem) {
        detailsId = (widget.media as HomeMediaItem).showId;
      }
      if (detailsId == null || detailsId <= 0) {
        detailsId = media.parentId;
      }
    }
    if (detailsId == null || detailsId <= 0) return;

    // Already resolved this session (detail page, or a previous playback):
    // set it synchronously so the chrome opens on the logo, not on the title.
    // The URL is normalised to the same size the detail header asked for, so
    // the bytes are in the image cache too and it draws on the first frame.
    final cached = MediaDetailsCache.peek(detailsId);
    if (cached != null) {
      setState(() => _mediaLogoUrl = logoImageUrl(cached.logoUrl));
      return;
    }

    final url = await MediaDetailsCache.resolveLogo(api, detailsId);
    if (!mounted) return;
    setState(() => _mediaLogoUrl = logoImageUrl(url));
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

  /// Resolves [_previousEpisode] from the current season listing.
  ///
  /// Season-crossing is deliberately not attempted: going back would mean
  /// fetching the previous season's episodes to find its last one, and the
  /// episode panel already covers that case.
  Future<void> _loadPreviousEpisode() async {
    final api = _apiClient;
    final seasonId = _currentSeasonId;
    if (!_isEpisode || api == null || seasonId == null || seasonId <= 0) return;

    try {
      final episodes = await api.getSeasonEpisodes(seasonId);
      if (!mounted) return;
      final idx = episodes.indexWhere((e) => e.media.id == _currentEpisodeId);
      if (idx <= 0) return;
      setState(() => _previousEpisode = episodes[idx - 1]);
    } catch (_) {
      // A missing back button is a smaller failure than a broken player.
    }
  }

  void _goToPreviousEpisode() {
    final previous = _previousEpisode;
    if (previous == null) return;
    _navigateToEpisode(previous);
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

      final showTitle =
          episodes.isNotEmpty && episodes.first.showTitle?.isNotEmpty == true
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
    if (AppPlatform.isWindows) {
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

    final resumePositionFuture = _loadResumePosition(apiClient, actualMedia);

    await _playerController.init(
      media: actualMedia,
      apiClient: apiClient,
      knownDurationSeconds: knownDuration,
      inheritedPreferences: widget.inheritedPreferences,
      // Handed over rather than awaited here: the controller needs the resume
      // point at the exact moment it opens the stream, so mpv can start at that
      // second instead of starting at 0 and seeking afterwards.
      resumePositionFuture: resumePositionFuture,
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
      onBufferingChanged: () {
        _safeSetState(() {});
      },
      onFirstFrame: () {
        // Lifts the start-up cover: the texture now holds this media.
        _safeSetState(() {});
        // Restart the auto-hide countdown here rather than leave the one armed
        // when play() was issued. On a slow open — a transcode taking several
        // seconds to produce a frame — that first countdown expired while the
        // screen was still covered, so the chrome was already gone by the time
        // the picture appeared and the player looked broken on arrival.
        _showControlsTransient();
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
      unawaited(_loadPreviousEpisode());
    }

    if (mounted) setState(() {});
    final resumeAt = await resumePositionFuture;
    if (!mounted) return;
    await _startPlayback(resumeAtSeconds: resumeAt);
  }

  void _safeSetState(VoidCallback fn) {
    if (_isDisposing || !mounted) return;
    try {
      setState(fn);
    } on Object {
      // Widget disposed between check and call
    }
  }

  bool _needsPositionUiRefresh() => _showControls || _showEpisodesPanel;

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
    // The early season offer wins over auto-advance: leaving would answer the
    // question by walking away from it. The card carries its own "next episode".
    if (_episodeNav?.nextEpisode != null &&
        !(_episodeNav?.showNextSeasonCard ?? false)) {
      _goToNextEpisode();
      return;
    }
    if (_episodeNav?.nextSeason != null) {
      // Leaving here would wipe the card at the exact moment the user is about
      // to act on it. Stay on the last frame and let them decide.
      _episodeNav!.revealNextSeasonCard();
      return;
    }
    unawaited(_leavePlayer());
  }

  Future<int> _loadResumePosition(
    ApiClient apiClient,
    Media actualMedia,
  ) async {
    // An episode reached by auto-advance always starts at zero, and the answer
    // below is discarded — so asking at all would just put an HTTP round-trip
    // in front of the picture, now that the open waits on this.
    if (widget.autoAdvance) return 0;

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
      debugPrint("Player: Failed to query progress: $e");
    }

    return (!widget.autoAdvance && savedPositionSeconds >= 3)
        ? savedPositionSeconds
        : 0;
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

  void _handleVideoTap({bool togglePlayback = false}) {
    _keyboardFocusNode.requestFocus();
    final layoutProvider =
        Provider.of<PlayerLayoutProvider>(context, listen: false);
    if (togglePlayback ||
        (layoutProvider.useModularLayout &&
            layoutProvider.config.tapToTogglePlayback)) {
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
      if (_showControls &&
          !_playerController.isDraggingSlider &&
          _playerController.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  /// Mouse moved over the video.
  ///
  /// Hover fires on every pointer sample — 60 to 120 times a second — and
  /// [_showControlsTransient] rebuilds the whole player tree, refreshes the
  /// timeline and re-measures the subtitle padding. Paying that per sample made
  /// the chrome stutter under the very gesture meant to summon it. When the
  /// chrome is already up there is nothing to show, so re-arming the countdown
  /// is the entire job.
  void _handlePointerHover() {
    _episodeNav?.onMouseMove();
    if (_showControls) {
      _hideControlsWithDelay();
      return;
    }
    _showControlsTransient();
  }

  void _showControlsTransient() {
    // The end-of-season page owns the screen: waking the HUD on every mouse
    // move would stack a progress bar and a play button over it.
    if (_episodeNav?.showNextSeasonCard ?? false) return;
    setState(() => _showControls = true);
    _refreshPositionUi(force: true);
    _scheduleSubtitlePaddingSync();
    _hideControlsWithDelay();
  }

  /// Whether the player chrome — timeline, transport, top-right menus — may be
  /// on screen. Single decision point so nothing slips through while the
  /// end-of-season page is up; only the back button survives it.
  bool get _controlsVisible =>
      _showControls && !(_episodeNav?.showNextSeasonCard ?? false);

  /// Netflix-style: hide the cursor while controls are hidden during playback.
  /// Never on the end-of-season page, which has buttons to aim at.
  bool get _shouldHideCursor =>
      !_showControls &&
      !(_episodeNav?.showNextSeasonCard ?? false) &&
      _playerController.isPlaying &&
      // Never during start-up. `isPlaying` goes true when play() is issued,
      // which on a slow open is seconds before there is any picture — hiding
      // the pointer over a black screen looks like the app froze.
      _playerController.hasFirstFrame &&
      !_playerController.isDraggingSlider;

  void _seekRelative(int seconds) {
    // The controller's position is absolute in both modes (HLS adds the
    // session's start offset), unlike mpv's own, which is relative to the
    // stream. Using the absolute one is what makes clamping against the full
    // duration correct, and lets the controller decide whether the target needs
    // a new HLS session.
    final maxSeconds = _playerController.duration.inSeconds;
    var target = _playerController.position.inSeconds + seconds;
    if (target < 0) target = 0;
    if (maxSeconds > 0 && target > maxSeconds) target = maxSeconds;
    _playerController.seekToAbsoluteSeconds(target);
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

  /// How much of the screen the video keeps. It gives way to the end-of-season
  /// card without ever being hidden: the credits stay visible and playing.
  double get _videoScale =>
      (_episodeNav?.showNextSeasonCard ?? false) ? 0.34 : 1.0;

  /// Corner radius of the shrunk video, pre-divided by the scale so it looks
  /// like 16pt on screen. Zero at full size, where rounding would just crop.
  double get _videoCornerRadius => _videoScale < 1 ? 16 / _videoScale : 0;

  Future<void> _requestNextSeason() async {
    final season = _episodeNav?.nextSeason;
    if (season == null || _requestingNextSeason || !season.canRequest) return;
    if (season.showTmdbId <= 0) return;

    setState(() => _requestingNextSeason = true);
    try {
      await _apiClient!.requestTmdbMedia(
        tmdbId: season.showTmdbId,
        mediaType: 'tv',
        title: season.showTitle,
        seasons: [season.number],
      );
      // Confirm in place (the card switches to its requested state) rather than
      // leaving the player: the credits are still running and the user chose
      // when to go.
      _episodeNav?.markNextSeasonRequested();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d’envoyer la demande.')),
        );
      }
    } finally {
      if (mounted) setState(() => _requestingNextSeason = false);
    }
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
    final inheritedPreferences = _playerController.exportPreferences();
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
          settings:
              const RouteSettings(name: SearchRouteObserver.playerRouteName),
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
    if (AppPlatform.isWindows) {
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

    final layoutProvider =
        Provider.of<PlayerLayoutProvider>(context, listen: false);
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

    final box =
        _timelineAnchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;

    return box.localToGlobal(Offset.zero).dy;
  }

  void _showTrackSettings({int initialTabIndex = 0}) {
    final renderBox =
        _settingsButtonKey.currentContext?.findRenderObject() as RenderBox?;
    // Fallback: center the panel when the settings button isn't on-canvas.
    final overlay = Overlay.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final hasChaptersTab = _episodeNav != null;
    final menuWidth =
        PlayerSettingsAnchor.sheetWidth(hasChaptersTab: hasChaptersTab);
    final menuMaxHeight =
        PlayerSettingsAnchor.sheetMaxHeight(hasChaptersTab: hasChaptersTab);

    late final double left;
    late final double? bottom;
    late final double? top;
    late final double maxHeight;
    if (renderBox != null) {
      final buttonRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
      left = PlayerSettingsAnchor.horizontalLeft(
        buttonRect: buttonRect,
        screenSize: screenSize,
        popupWidth: menuWidth,
      );
      final vertical = PlayerSettingsAnchor.verticalPlacement(
        buttonRect: buttonRect,
        screenSize: screenSize,
        popupMaxHeight: menuMaxHeight,
      );
      bottom = vertical.bottom;
      top = vertical.top;
      maxHeight = vertical.maxHeight;
    } else {
      left = (screenSize.width - menuWidth) / 2;
      top = (screenSize.height - menuMaxHeight) / 2;
      bottom = null;
      maxHeight = menuMaxHeight;
    }

    final maxTab = hasChaptersTab ? 4 : 3;
    final tab = initialTabIndex.clamp(0, maxTab);

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
                  bottom: bottom,
                  top: top,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: PlayerSettingsSheet(
                      player: _playerController.player,
                      currentFit: _videoFit,
                      onFitChanged: _updateVideoFit,
                      onClose: entry.remove,
                      playerController: _playerController,
                      episodeNav: _episodeNav,
                      onSeekToAbsolute: _playerController.seekToAbsoluteSeconds,
                      initialTabIndex: tab,
                    ),
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

  /// Emby-chrome settings menu, anchored to the button that opened it.
  void _showEmbySettingsMenu({
    EmbyMenuSection section = EmbyMenuSection.root,
    required GlobalKey anchorKey,
  }) {
    final overlay = Overlay.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final renderBox = anchorKey.currentContext?.findRenderObject() as RenderBox?;

    const menuWidth = EmbySettingsMenu.width;
    const menuMaxHeight = EmbySettingsMenu.maxHeight;

    late final double left;
    late final double? bottom;
    late final double? top;
    late final double maxHeight;
    if (renderBox != null) {
      final buttonRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
      left = PlayerSettingsAnchor.horizontalLeft(
        buttonRect: buttonRect,
        screenSize: screenSize,
        popupWidth: menuWidth,
      );
      final vertical = PlayerSettingsAnchor.verticalPlacement(
        buttonRect: buttonRect,
        screenSize: screenSize,
        popupMaxHeight: menuMaxHeight,
      );
      bottom = vertical.bottom;
      top = vertical.top;
      maxHeight = vertical.maxHeight;
    } else {
      left = (screenSize.width - menuWidth) / 2;
      top = (screenSize.height - menuMaxHeight) / 2;
      bottom = null;
      maxHeight = menuMaxHeight;
    }

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
                  bottom: bottom,
                  top: top,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: EmbySettingsMenu(
                      player: _playerController.player,
                      playerController: _playerController,
                      episodeNav: _episodeNav,
                      currentFit: _videoFit,
                      onFitChanged: _updateVideoFit,
                      playbackRate: _playbackRate,
                      playbackRates: _playbackRates,
                      onRateChanged: _setPlaybackRate,
                      onSeekToAbsolute:
                          _playerController.seekToAbsoluteSeconds,
                      initialSection: section,
                      onClose: entry.remove,
                    ),
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

  Future<void> _setPlaybackRate(double rate) async {
    await _playerController.player.setRate(rate);
    if (!mounted) return;
    setState(() => _playbackRate = rate);
    _showControlsTransient();
  }

  Future<void> _cyclePlaybackRate() async {
    final idx = _playbackRates.indexOf(_playbackRate);
    final next = _playbackRates[(idx < 0 ? 0 : idx + 1) % _playbackRates.length];
    await _playerController.player.setRate(next);
    if (!mounted) return;
    setState(() => _playbackRate = next);
    _showControlsTransient();
  }

  void _toggleAspectFitControl() {
    final next =
        _videoFit == BoxFit.contain ? BoxFit.cover : BoxFit.contain;
    _updateVideoFit(next);
    _showControlsTransient();
  }

  Future<void> _skipIntroFromControl() async {
    final nav = _episodeNav;
    if (nav == null || !nav.showSkipIntro) return;
    final end = nav.introSkipTarget;
    await _playerController.seekToAbsoluteSeconds(end);
    nav.skipIntro();
    _showControlsTransient();
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
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: vertical.maxHeight),
                    child: PlayerSubtitlesSheet(
                      player: _playerController.player,
                      playerController: _playerController,
                      onClose: entry.remove,
                    ),
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

  /// The episode's own title (TV) or the media title (movies) — as opposed
  /// to [_episodesShowTitle], which is the show name. `_playerTitle` combines
  /// show name + code and must not be used here or the code/title repeat.
  String get _episodeOrMovieTitle {
    final media = widget.media;
    if (media is HomeMediaItem && media.media.type == MediaType.episode) {
      return media.episodeTitle ?? media.media.title;
    }
    return _episodesShowTitle;
  }

  /// Composes the small muted line shown by [PlayerControlType.episodeTitleBlock]
  /// and reused as the header line of the info panel.
  String get _episodeInfoLine => composeEpisodeInfoLine(
        seasonEpisodeCode: _actualMedia.seasonEpisodeCode,
        title: _episodeOrMovieTitle,
        filePath: _actualMedia.filePath,
      );

  /// Same line without the release tag parsed from the filename. The chrome
  /// over the video names the episode; the quality/source belongs to the info
  /// panel, which is where someone goes looking for it.
  String get _episodeOverline => composeEpisodeInfoLine(
        seasonEpisodeCode: _actualMedia.seasonEpisodeCode,
        title: _episodeOrMovieTitle,
      );

  /// Bold line of the Emby title block: the show name on an episode, the film
  /// title on a movie.
  String get _embyTitleLine => _episodesShowTitle;

  /// Muted line above it: `S1:E3 - …` on an episode, the release year on a
  /// movie — which is what Emby shows there.
  String? get _embyOverline {
    if (_isEpisode) return _episodeOverline;
    return extractYear(_actualMedia.releaseDate);
  }

  /// Downloaded-ahead fraction for the Emby scrubber.
  double get _bufferedFraction {
    final total = _playerController.duration.inSeconds;
    if (total <= 0) return 0;
    return (_playerController.player.state.buffer.inSeconds / total)
        .clamp(0.0, 1.0);
  }

  /// Chapter starts as fractions, for the Emby scrubber ticks. Empty when the
  /// backend found no chapters — the bar then reads as a plain timeline.
  List<double> get _chapterMarks {
    final chapters = _episodeNav?.chapters ?? const [];
    final total = _playerController.duration.inSeconds;
    if (chapters.isEmpty || total <= 0) return const [];
    return [
      for (final chapter in chapters)
        (chapter.startTime / total).clamp(0.0, 1.0),
    ];
  }

  void _showInfoPanel() {
    final renderBox =
        _mediaInfoButtonKey.currentContext?.findRenderObject() as RenderBox?;

    final overlay = Overlay.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    const cardWidth = 560.0;
    const cardMaxHeight = 220.0;

    late final double left;
    late final double? bottom;
    late final double? top;
    late final double maxHeight;
    if (renderBox != null) {
      final buttonRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
      left = PlayerSettingsAnchor.horizontalLeft(
        buttonRect: buttonRect,
        screenSize: screenSize,
        popupWidth: cardWidth,
      );
      final vertical = PlayerSettingsAnchor.verticalPlacement(
        buttonRect: buttonRect,
        screenSize: screenSize,
        popupMaxHeight: cardMaxHeight,
      );
      bottom = vertical.bottom;
      top = vertical.top;
      maxHeight = vertical.maxHeight;
    } else {
      left = (screenSize.width - cardWidth) / 2;
      top = (screenSize.height - cardMaxHeight) / 2;
      bottom = null;
      maxHeight = cardMaxHeight;
    }

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
                  bottom: bottom,
                  top: top,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: PlayerInfoSheet(
                      media: _actualMedia,
                      showTitle: _episodesShowTitle,
                      episodeInfoLine: _episodeInfoLine,
                      tracks: _playerController.mediaTracks,
                      duration: _playerController.duration,
                      onRestart: () {
                        entry.remove();
                        _playerController.seekToAbsoluteSeconds(0);
                      },
                      onClose: entry.remove,
                    ),
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
    final isFullScreen = await WindowControls.isFullScreen();
    await WindowControls.setFullScreen(!isFullScreen);
  }

  Future<void> _exitFullscreenIfActive() async {
    if (await WindowControls.isFullScreen()) {
      await WindowControls.setFullScreen(false);
    }
  }

  void _togglePlayPause() {
    _playerController.togglePlayPause();
    _hideControlsWithDelay();
  }

  /// Seek from a progress-bar fraction — the modular (Player Studio) layout's
  /// only seek path.
  ///
  /// It used to call player.seek() directly with `fraction * duration`, which is
  /// an ABSOLUTE position, while mpv expects a position on the HLS stream
  /// timeline — and that timeline restarts at 0 at the session's start offset.
  /// Seeking to an absolute value therefore overshot by the whole offset, mpv
  /// clamped it to the end of what had been encoded so far, and the player
  /// parked there waiting on segments that did not exist yet. Going through the
  /// controller applies the offset and, just as importantly, lets it decide
  /// whether the target needs a fresh session instead of an in-session seek.
  void _seekToFraction(double fraction) {
    final totalSeconds = _playerController.duration.inSeconds;
    if (totalSeconds <= 0) return;
    _playerController
        .seekToAbsoluteSeconds((fraction * totalSeconds).round());
    _showControlsTransient();
  }

  @override
  Widget build(BuildContext context) {
    final layoutProvider = Provider.of<PlayerLayoutProvider>(context);
    // A fixed chrome is its own thing: it is neither the default HUD nor the
    // modular layer, and it ignores the layout config entirely.
    final fixedChrome = layoutProvider.fixedChrome;
    final useModular = fixedChrome == null && layoutProvider.useModularLayout;
    final useDefaultHud = fixedChrome == null && !useModular;
    final totalSeconds = _playerController.duration.inSeconds;
    final progressFraction = totalSeconds > 0
        ? _playerController.position.inSeconds / totalSeconds
        : 0.0;

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
            cursor:
                _shouldHideCursor ? SystemMouseCursors.none : MouseCursor.defer,
            onHover: (event) => _handlePointerHover(),
            child: Stack(
              children: [
                // The video shrinks into a corner while the end-of-season card
                // is up, so the credits stay watchable — the card never hides
                // what is still playing. Scaling instead of resizing keeps the
                // media_kit texture at one size, which avoids a reallocation
                // hitch mid-animation.
                RepaintBoundary(
                  child: AnimatedScale(
                    scale: _videoScale,
                    alignment: Alignment.centerLeft,
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    child: AnimatedPadding(
                      padding: EdgeInsets.all(_videoScale < 1 ? 26 : 0),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      // Radius and shadow are divided by the scale so they read
                      // at their intended size once shrunk, instead of being
                      // squashed along with the picture.
                      child: AnimatedPhysicalModel(
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeOutCubic,
                        color: Colors.black,
                        shadowColor: Colors.black,
                        elevation: _videoScale < 1 ? 24 / _videoScale : 0,
                        borderRadius:
                            BorderRadius.circular(_videoCornerRadius),
                        clipBehavior: Clip.antiAlias,
                        animateColor: false,
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
                    ),
                  ),
                ),
                // Dimming scrim for a session rebuild. It sits here — directly
                // above the video and BELOW the controls — so it veils the
                // stale frame without also greying out the buttons the user
                // needs while loading. The spinner itself stays at the top of
                // the stack.
                if (_playerController.isSwitchingQuality)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(color: Colors.black54),
                    ),
                  ),
                // Start-up cover. Same place as the scrim above — over the
                // video, under the controls — so the back button and the title
                // stay usable while the stream opens.
                //
                // It is held until the decoder has produced a frame of *this*
                // media, not until startPlayback() returns. The engine texture
                // is pooled and still shows the previous title until then, and
                // between the two the picture was either that stale frame or
                // black with nothing on it.
                if (!_playerController.hasFirstFrame)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(color: Colors.black),
                    ),
                  ),
                Positioned.fill(
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTap: () => _seekRelative(-10),
                          onTap: _handleVideoTap,
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _handleVideoTap(togglePlayback: true),
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTap: () => _seekRelative(10),
                          onTap: _handleVideoTap,
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    ],
                  ),
                ),
                // Switched on rather than compared, so adding a chrome to
                // [FixedChromeId] fails to compile here instead of silently
                // rendering a player with no controls at all.
                if (fixedChrome != null)
                  switch (fixedChrome) {
                    FixedChromeId.emby => EmbyControlsLayer(
                    visible: _controlsVisible,
                    timelineAnchorKey: _timelineAnchorKey,
                    isPlaying: _playerController.isPlaying,
                    position: _playerController.position,
                    duration: _playerController.duration,
                    buffered: _bufferedFraction,
                    onPlayPause: _togglePlayPause,
                    onRewind: () => _seekRelative(-10),
                    onForward: () => _seekRelative(10),
                    onSeekFraction: _seekToFraction,
                    onScrubbingChanged: (scrubbing) {
                      // Hold the chrome open for the whole drag, then start
                      // the hide countdown again on release.
                      if (scrubbing) {
                        _controlsTimer?.cancel();
                        _safeSetState(() => _showControls = true);
                      } else {
                        _hideControlsWithDelay();
                      }
                    },
                    title: _embyTitleLine,
                    overline: _embyOverline,
                    logoUrl: _mediaLogoUrl,
                    volume: _playerController.player.state.volume,
                    onVolumeChanged: (v) =>
                        _playerController.player.setVolume(v),
                    onBack: _leavePlayer,
                    // This chrome gets the Emby-shaped menu, not the tabbed
                    // panel the modular and default layouts use.
                    onToggleSubtitles: () => _showEmbySettingsMenu(
                      section: EmbyMenuSection.subtitles,
                      anchorKey: _subtitlesButtonKey,
                    ),
                    onOpenAudio: () => _showEmbySettingsMenu(
                      section: EmbyMenuSection.audio,
                      anchorKey: _subtitlesButtonKey,
                    ),
                    onCycleSpeed: _cyclePlaybackRate,
                    onOpenSettings: () => _showEmbySettingsMenu(
                      anchorKey: _settingsButtonKey,
                    ),
                    onToggleFullscreen: _toggleFullscreen,
                    playbackRate: _playbackRate,
                    onSkipNext: (_episodeNav?.nextEpisode != null)
                        ? _goToNextEpisode
                        : null,
                    onSkipPrevious:
                        _previousEpisode != null ? _goToPreviousEpisode : null,
                    onOpenEpisodes: _isEpisode ? _openEpisodesPanel : null,
                    onSkipIntro: (_episodeNav?.showSkipIntro ?? false)
                        ? _skipIntroFromControl
                        : null,
                    chapterMarks: _chapterMarks,
                    settingsButtonKey: _settingsButtonKey,
                    subtitlesButtonKey: _subtitlesButtonKey,
                  ),
                  }
                else if (useModular) ...[
                  ModularControlsLayer(
                    config: layoutProvider.config,
                    visible: _controlsVisible,
                    timelineAnchorKey: _timelineAnchorKey,
                    isPlaying: _playerController.isPlaying,
                    progress: progressFraction,
                    duration: _playerController.duration,
                    currentSeconds: _playerController.position.inSeconds,
                    onPlayPause: _togglePlayPause,
                    onRewind: () => _seekRelative(-10),
                    onForward: () => _seekRelative(10),
                    onRewind30: () => _seekRelative(-30),
                    onForward30: () => _seekRelative(30),
                    onSkipNext: (_episodeNav?.nextEpisode != null)
                        ? _goToNextEpisode
                        : null,
                    onSeekFraction: _seekToFraction,
                    onToggleFullscreen: _toggleFullscreen,
                    mediaTitle: _playerTitle,
                    mediaLogoUrl: _mediaLogoUrl,
                    volume: _playerController.player.state.volume,
                    onVolumeChanged: (v) =>
                        _playerController.player.setVolume(v),
                    onBack: _leavePlayer,
                    onOpenSettings: () => _showTrackSettings(),
                    onToggleSubtitles: _showSubtitlesMenu,
                    onOpenUpNext: _isEpisode ? _openEpisodesPanel : null,
                    onSkipIntro: (_episodeNav?.showSkipIntro ?? false)
                        ? _skipIntroFromControl
                        : null,
                    onCycleSpeed: _cyclePlaybackRate,
                    onToggleAspectFit: _toggleAspectFitControl,
                    onOpenAudio: () => _showTrackSettings(initialTabIndex: 0),
                    onOpenChapters: _episodeNav != null
                        ? () => _showTrackSettings(initialTabIndex: 4)
                        : null,
                    onOpenInfo: _showInfoPanel,
                    episodeInfoLine: _episodeOverline,
                    episodeShowTitle: _episodesShowTitle,
                    playbackRate: _playbackRate,
                    videoFit: _videoFit,
                    settingsButtonKey: _settingsButtonKey,
                    subtitlesButtonKey: _subtitlesButtonKey,
                    mediaInfoButtonKey: _mediaInfoButtonKey,
                  ),
                ] else
                  PlayerHUDOverlay(
                    visible: _controlsVisible,
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
                        await (_playerController.player.platform as dynamic)
                            .setProperty('hr-seek', 'no');
                      } catch (_) {}
                    },
                    onSliderChanged: (value) {
                      _playerController.dragValue = value;
                      // Scrub live only where the session can already serve the
                      // frame; dragging past that would stall mpv on segments
                      // that do not exist yet. The final position is committed
                      // in onSliderChangeEnd.
                      if (_playerController.canSeekWithinSession(value.toInt())) {
                        _playerController.player.seek(Duration(
                            seconds: value.toInt() -
                                _playerController.hlsStartOffset));
                      }
                      _safeSetState(() {});
                    },
                    onSliderChangeEnd: (value) async {
                      _playerController.isDraggingSlider = false;
                      // One decision point: this rebuilds the HLS session only
                      // if the target is outside what it can serve. Rewinding
                      // stays a plain seek.
                      await _playerController
                          .seekToAbsoluteSeconds(value.toInt());
                      if (_playerController.currentQuality == null) {
                        try {
                          await (_playerController.player.platform as dynamic)
                              .setProperty('hr-seek', 'yes');
                        } catch (_) {}
                      }
                      _hideControlsWithDelay();
                    },
                    onNextEpisode: (_episodeNav?.nextEpisode != null)
                        ? _goToNextEpisode
                        : null,
                  ),
                if (_controlsVisible && useDefaultHud)
                  TopRightControls(
                    player: _playerController.player,
                    currentFit: _videoFit,
                    onFitChanged: _updateVideoFit,
                    playerController: _playerController,
                    episodeNav: _episodeNav,
                    onSeekToAbsolute: _playerController.seekToAbsoluteSeconds,
                  ),
                // Overlays must be AFTER HUD in Stack to render on top.
                // If the Studio layout already places a skip-intro control —
                // or the fixed chrome draws its own — hide the built-in
                // overlay to avoid a duplicate CTA.
                if ((_episodeNav?.showSkipIntro ?? false) &&
                    fixedChrome == null &&
                    !(useModular &&
                        layoutProvider.config
                            .hasControl(PlayerControlType.skipIntro)))
                  SkipIntroButton(
                    onSkip: () async {
                      final end = _episodeNav!.introSkipTarget;
                      await _playerController.seekToAbsoluteSeconds(end);
                      _episodeNav!.skipIntro();
                    },
                  ),
                // Requires an actual next episode: at the end of a season the
                // pill would otherwise sit there doing nothing when tapped.
                if ((_episodeNav?.showNextEpisodeOutro ?? false) &&
                    _episodeNav?.nextEpisode != null &&
                    !(_episodeNav?.showNextSeasonCard ?? false))
                  NextEpisodeOverlay(
                    nextEpisode: _episodeNav!.nextEpisode,
                    autoPlayActive: _episodeNav!.outroAutoPlayActive,
                    frozen: _episodeNav!.outroAutoPlayFrozen,
                    countdownSeconds: _episodeNav!.outroCountdownSeconds,
                    onPlayNext: _goToNextEpisode,
                    onCancel: () => _episodeNav!.cancelAutoPlay(),
                  ),
                // Tapping the shrunk video is a second way to say "no thanks":
                // it dismisses the page and gives the picture and the controls
                // back. Placed before the back button so that button, which
                // sits inside this same strip, still gets the tap.
                if (_episodeNav?.showNextSeasonCard ?? false)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: 0,
                    width: MediaQuery.of(context).size.width * _videoScale,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _episodeNav!.dismissNextSeasonCard(),
                      ),
                    ),
                  ),
                // The only chrome that survives the end-of-season page: without
                // it the page would be a dead end, since every other way out is
                // hidden.
                if (_episodeNav?.showNextSeasonCard ?? false)
                  Positioned(
                    top: macOSWindowControlsTopInset + 12,
                    left: 20,
                    child: _PlayerBackButton(onTap: _leavePlayer),
                  ),
                if (_episodeNav?.showNextSeasonCard ?? false)
                  NextSeasonOverlay(
                    season: _episodeNav!.nextSeason!,
                    submitting: _requestingNextSeason,
                    onRequest: _requestNextSeason,
                    onDismiss: () => _episodeNav!.dismissNextSeasonCard(),
                    onPlayNext: (_episodeNav?.isSeasonLookahead ?? false)
                        ? _goToNextEpisode
                        : null,
                    videoInset:
                        MediaQuery.of(context).size.width * _videoScale,
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
                // Start-up spinner. IgnorePointer like the two below: loading is
                // exactly when the user may want to go back, so the cover must
                // never eat taps meant for the chrome.
                if (!_playerController.hasFirstFrame)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF00A4DC),
                          strokeWidth: 3,
                        ),
                      ),
                    ),
                  ),
                // Both spinners below are IgnorePointer, not AbsorbPointer: they
                // cover the whole screen and sit above the controls, so
                // absorbing taps made every player button dead for as long as a
                // seek took to load. Loading is exactly when the user is most
                // likely to want to pause, seek again or go back, so the
                // spinner has to be purely decorative.
                if (_playerController.isSwitchingQuality ||
                    (_playerController.isBuffering && _isInitialized))
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF00A4DC),
                          strokeWidth: 3,
                        ),
                      ),
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


/// Standalone back control, shown while the end-of-season page hides the rest
/// of the player chrome. Kept independent of the HUD so it cannot be swept away
/// with it.
class _PlayerBackButton extends StatefulWidget {
  final VoidCallback onTap;

  const _PlayerBackButton({required this.onTap});

  @override
  State<_PlayerBackButton> createState() => _PlayerBackButtonState();
}

class _PlayerBackButtonState extends State<_PlayerBackButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: _hovered ? 0.62 : 0.38),
            border: Border.all(
              color: _hovered ? Colors.white24 : Colors.white10,
            ),
          ),
          child: Icon(
            Icons.arrow_back_rounded,
            size: 20,
            color: _hovered ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}
