import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../utils/app_platform.dart';
import '../../utils/window_controls.dart';
import '../../models/models.dart';
import '../../models/player_layout.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/player_layout_provider.dart';
import '../../navigation/search_route_observer.dart';
import '../../services/api_client.dart';
import '../../services/download_manager.dart';
import '../../services/server_reachability.dart';
import '../../services/media_details_cache.dart';
import '../../services/screen_brightness_control.dart';
import 'display_cutouts.dart';
import '../../tv/tv_mode.dart';
import '../../utils/poster_url.dart';
import 'hooks/use_player_controller.dart';
import 'hooks/use_episode_navigation.dart';
import 'hooks/use_player_media_keys.dart';
import 'widgets/skip_intro_button.dart';
import 'widgets/seek_feedback_overlay.dart';
import 'widgets/video_zoom_hint.dart';
import 'widgets/next_episode_overlay.dart';
import 'widgets/next_season_overlay.dart';
import 'widgets/upcoming_episode_overlay.dart';
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
import 'pinch_zoom_fit.dart';
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

  /// The picture has not arrived, and it has been long enough that saying
  /// nothing is worse than saying the wrong thing.
  ///
  /// A start-up that stalls used to be indistinguishable from one that is
  /// merely slow: the same spinner, forever. It is the network far more often
  /// than not — a television on the far end of the Wi-Fi, a connect that hangs
  /// where a retry would have worked — and none of that is visible from a
  /// spinner. So the wait is given a deadline and an offer to try again.
  bool _startupStalled = false;
  Timer? _startupWatchdog;

  /// How long the picture may take before the screen admits something is wrong.
  ///
  /// Long enough not to fire on a genuinely slow open — a big remux over a
  /// weak link, a server that has to spin a disk up — and short enough that
  /// nobody sits through it twice wondering whether to press something.
  static const Duration _startupDeadline = Duration(seconds: 25);

  /// True from the moment this screen starts leaving — a pop, or a jump to the
  /// next episode. The focus is on its way to another screen from here on, and
  /// this one must stop claiming it back.
  bool _isLeaving = false;
  bool _progressFlushed = false;
  ApiClient? _apiClient;

  /// How the video is fitted inside the player viewport.
  /// [BoxFit.contain] = original (letterbox possible).
  /// [BoxFit.cover]   = adaptive (fills screen, may crop edges).
  BoxFit _videoFit = BoxFit.contain;

  /// Pinch-to-zoom, the gesture Netflix and YouTube both answer on a phone:
  /// spreading two fingers fills the screen ([BoxFit.cover]), pinching them
  /// back gives the original framing ([BoxFit.contain]). Reading the pinch
  /// itself belongs to [PinchZoomFit]; what is left here is when to listen and
  /// what to do with the answer.
  ///
  /// One fit decision per pinch. Without it, fingers drifting back across the
  /// threshold mid-gesture would keep flipping the picture.
  bool _pinchResolved = false;

  /// Screen brightness override, 0.0 -> 1.0, or null on a screen whose
  /// backlight this app does not drive. Null is what keeps the left-hand bar
  /// out of the chrome everywhere except a phone or tablet.
  double? _screenBrightness;

  BoxFit _zoomHintFit = BoxFit.contain;
  bool _zoomHintVisible = false;
  bool _zoomHintMounted = false;
  Timer? _zoomHintTimer;

  /// Running total of a burst of double-tap seeks, in seconds. Reset once the
  /// taps stop, or the moment one goes the other way.
  int _seekHintSeconds = 0;
  bool _seekHintForward = true;

  /// Bumped per tap so the overlay can replay its arc; see
  /// [SeekFeedbackOverlay.pulse].
  int _seekHintPulse = 0;
  bool _seekHintVisible = false;
  bool _seekHintMounted = false;
  Timer? _seekHintTimer;

  /// Pack Cinéma — playback rate cycle for studio control.
  double _playbackRate = 1.0;
  static const _playbackRates = [0.75, 1.0, 1.25, 1.5, 2.0];

  /// Key attached to the settings button so we can anchor the popup above it.
  final GlobalKey _settingsButtonKey = GlobalKey();

  /// Key attached to the subtitles button so we can anchor the popup above it.
  final GlobalKey _subtitlesButtonKey = GlobalKey();

  /// Key attached to the media-info button so we can anchor the info card above it.
  final GlobalKey _mediaInfoButtonKey = GlobalKey();


  /// Anchors subtitle lift to the real progress/timeline bar position.
  final GlobalKey _timelineAnchorKey = GlobalKey();

  final FocusNode _keyboardFocusNode = FocusNode(debugLabel: 'player');

  /// The control the remote is handed when it enters the control bar.
  ///
  /// Play/pause is the button a hand reaches for first, and on a chrome laid
  /// out like a control bar every other button is one or two presses from it.
  /// Traversal order would otherwise decide, and traversal order picks
  /// whatever happens to be first in the tree.
  final FocusNode _playPauseFocusNode =
      FocusNode(debugLabel: 'player-play-pause');

  /// The scrubber — where the remote actually lands when the HUD comes up.
  ///
  /// Emby's television player never leaves the viewer guessing: the instant
  /// the HUD is on screen something is outlined, and that something is the
  /// bar. Left and right therefore keep meaning "seek", exactly as they did
  /// with the HUD down, and now the screen says so. Play/pause is one press
  /// away, and OK on the bar itself toggles it.
  final FocusNode _progressFocusNode = FocusNode(debugLabel: 'player-progress');

  /// The settings / subtitles / info popup currently on the overlay, with the
  /// closure that dismisses it. Back goes through this before it reaches the
  /// player. One at a time: each of these covers the screen with its own
  /// dismiss barrier, so a second one stacked on it would be unreachable.
  ({OverlayEntry entry, VoidCallback dismiss})? _openPopup;

  /// Focus scope lent to whichever popup is open, so a remote can walk into a
  /// menu that is not a route and would otherwise never receive the focus.
  final FocusScopeNode _popupFocusScope =
      FocusScopeNode(debugLabel: 'player-popup');

  static const double _volumeStep = 5.0;

  /// Whether this screen may take over the device's orientation and system
  /// bars for the duration of a playback.
  ///
  /// A phone, yes: a film is landscape and the phone is not. A television,
  /// never — it cannot rotate, and the portrait request this screen used to
  /// issue on the way out handed the app back to the shell in a portrait-shaped
  /// window. That is the "it comes back in phone mode" after leaving a film:
  /// the bottom tab bar, the narrow layout, on a 16:9 screen. It also has no
  /// system bars for immersive mode to hide.
  static bool get _ownsDeviceOrientation =>
      AppPlatform.isMobile && !TvMode.isTv;

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

  /// Quel playeur habille cette lecture.
  ///
  /// Le compte fait foi dès que le serveur a confirmé lequel il utilise. Sinon
  /// — hors ligne, ou avant la première synchronisation de la session — un
  /// média téléchargé en sait plus que l'app : l'instantané rangé avec lui
  /// porte le playeur du compte **du serveur d'où il vient**, là où le provider
  /// ne tient qu'une trace locale, qui peut appartenir à un autre compte ou
  /// n'avoir jamais été renseignée. Sans ça un épisode téléchargé s'ouvrait
  /// sur le HUD par défaut, que personne n'avait choisi.
  _ResolvedChrome _resolveChrome(PlayerLayoutProvider provider) {
    if (!provider.isSyncedWithAccount) {
      final snapshot = DownloadManager.instance.chromeFor(_actualMedia.id);
      if (snapshot != null) {
        return _ResolvedChrome(
          config: snapshot.config,
          useModular: snapshot.useModular,
        );
      }
    }
    return _ResolvedChrome(
      config: provider.config,
      useModular: provider.useModularLayout,
    );
  }

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
    if (_ownsDeviceOrientation) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (AppPlatform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDesktopCaption.value = false;
      });
    }
    unawaited(_loadScreenBrightness());
    _keyboardFocusNode.addListener(_handlePlayerFocusChanged);
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
    _seedOfflineDetails();

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
        // The picture is here; nothing left for the deadline to catch.
        _startupWatchdog?.cancel();
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
        session: _playerController.session,
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

  /// Verse la fiche rapatriée avec ce média dans le cache que lisent les
  /// écrans, pour que le logo-titre et le reste existent sans serveur.
  ///
  /// Uniquement hors ligne : en ligne, la fiche du serveur est plus fraîche, et
  /// pré-remplir le cache la retarderait de sa durée de validité.
  void _seedOfflineDetails() {
    final reachability =
        Provider.of<ServerReachability>(context, listen: false);
    if (reachability.isOnline) return;
    final downloads = DownloadManager.instance;
    final details = downloads.offlineDetails(_actualMedia.id);
    if (details == null) return;
    // Sous l'identifiant qui a servi à la demander : le lecteur cherche la
    // fiche par l'identifiant de la série, pas par celui de l'épisode.
    final infoId = downloads.entryFor(_actualMedia.id)?.infoId;
    MediaDetailsCache.remember(infoId ?? details.id, details);
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
    // An end card wins over auto-advance: leaving would answer its question by
    // walking away from it, and both cards carry their own "next episode".
    // Staying on the last frame is what keeps them there to be acted on.
    //
    // The gap card goes first: when the library holds a later season, crossing
    // a hole in this one has to stay a deliberate act, never an auto-advance.
    if (_episodeNav?.revealUpcomingEpisodeCard() ?? false) return;
    if (_episodeNav?.nextEpisode != null && !_endCardVisible) {
      _goToNextEpisode();
      return;
    }
    if (_episodeNav?.revealNextSeasonCard() ?? false) return;
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

    // Une lecture hors ligne pas encore rejouée fait autorité : le serveur en
    // est resté à la dernière fois qu'il a eu des nouvelles, et lui demander
    // reviendrait à rembobiner l'épisode qu'on vient de regarder dans le train.
    final offline = DownloadManager.instance.entryFor(actualMedia.id);
    if (offline != null && offline.needsSync) {
      savedPositionSeconds = offline.isFinished ? 0 : offline.positionSeconds;
    } else {
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
        // Serveur injoignable : le manifeste local est tout ce qui reste, et
        // pour un média téléchargé c'est exactement ce qu'il faut.
        if (offline != null) {
          savedPositionSeconds = offline.isFinished ? 0 : offline.positionSeconds;
        }
      }
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
    _armStartupWatchdog();
    _scheduleSubtitlePaddingSync();
    unawaited(_mediaKeys.attach(
      title: _playerTitle,
      durationSeconds: _playerController.duration.inSeconds,
      positionSeconds: _playerController.position.inSeconds,
    ));
    _keyboardFocusNode.requestFocus();
    _hideControlsWithDelay();
  }

  /// Starts the countdown on the first picture. Cancelled the moment it lands;
  /// re-armed by a retry.
  void _armStartupWatchdog() {
    _startupWatchdog?.cancel();
    if (_playerController.hasFirstFrame) return;
    _startupWatchdog = Timer(_startupDeadline, () {
      if (!mounted || _isDisposing) return;
      if (_playerController.hasFirstFrame) return;
      setState(() => _startupStalled = true);
    });
  }

  /// Opens this same media again, from scratch.
  ///
  /// A fresh screen rather than a seek or a re-open on the spot: the engine,
  /// its HTTP connection and every subscription are rebuilt, which is what a
  /// stalled start needs — whatever it got stuck on is not worth diagnosing
  /// from here.
  void _retryPlayback() {
    if (!mounted) return;
    _startupWatchdog?.cancel();
    _isLeaving = true;
    _playerController.cancelStreams();
    final inheritedPreferences = _playerController.exportPreferences();
    final videoFit = _videoFit;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
        builder: (_) => PlayerScreen(
          media: widget.media,
          inheritedPreferences: inheritedPreferences,
          initialVideoFit: videoFit,
          seasonNumber: widget.seasonNumber,
        ),
      ),
    );
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

  /// Whether a tap on the video means "play/pause" or "show me the chrome".
  ///
  /// On a touchscreen there is no pointer to hover, so the same tap has to do
  /// both jobs, and which one it does is decided by what is already on screen:
  /// no chrome means the tap was a request to see it, chrome up means the tap
  /// landed on a player whose controls the user can already read — so it drives
  /// playback. A phone with no chrome showing pausing the film out from under
  /// a finger placed to *find* the controls is the behaviour this replaces.
  bool get _tapDrivesPlayback => _controlsVisible;

  void _handleVideoTap({bool togglePlayback = false}) {
    _keyboardFocusNode.requestFocus();

    // Touch: one rule for all three zones, so the middle of the screen is not
    // a different player from its edges.
    if (_touchTapRules) {
      if (_tapDrivesPlayback) _togglePlayPause();
      // Either way the chrome comes up and its countdown restarts: the tap
      // that revealed it, and the tap that used it, both mean "I am here".
      _showControlsTransient();
      return;
    }

    final chrome = _resolveChrome(
        Provider.of<PlayerLayoutProvider>(context, listen: false));
    if (togglePlayback ||
        (chrome.useModular && chrome.config.tapToTogglePlayback)) {
      _togglePlayPause();
      _showControlsTransient();
      return;
    }
    _toggleControls();
  }

  /// Phones and tablets, but not a television: a remote drives the chrome with
  /// its own keys and never produces a tap.
  bool get _touchTapRules => AppPlatform.isMobile && !TvMode.isTv;

  /// Reads the brightness the screen is already on, so the bar opens where the
  /// user left it instead of jumping on first touch.
  Future<void> _loadScreenBrightness() async {
    final value = await ScreenBrightnessControl.current();
    if (value == null || !mounted || _isDisposing) return;
    setState(() => _screenBrightness = value);
  }

  void _setScreenBrightness(double value) {
    setState(() => _screenBrightness = value.clamp(0.0, 1.0));
    unawaited(ScreenBrightnessControl.set(value));
  }

  void _hideControlsWithDelay() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (_isDisposing) return;
      if (!mounted) return;
      if (_playerController.isDraggingSlider) return;
      // A paused film keeps its chrome: there is nothing behind it to watch.
      if (!_playerController.isPlaying) return;
      // The remote has been parked on a button for the whole countdown. The
      // bar goes — but the focus has to leave with it, or the next arrow press
      // lands on a control nobody can see and the player stops answering its
      // own keys. This used to re-arm the timer instead, which meant a chrome
      // the remote had touched once never went away again.
      if (_remoteBrowsingControls) {
        _leaveControlBar();
        return;
      }
      if (_showControls) {
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

  /// Whether one of the end-of-episode pages — the season request or the
  /// episode this season still awaits — currently owns the screen.
  bool get _endCardVisible => _episodeNav?.showEndCard ?? false;

  void _showControlsTransient() {
    // The end card owns the screen: waking the HUD on every mouse move would
    // stack a progress bar and a play button over it.
    if (_endCardVisible) return;
    setState(() => _showControls = true);
    _refreshPositionUi(force: true);
    _scheduleSubtitlePaddingSync();
    _hideControlsWithDelay();
    // Every route that raises the chrome goes through here, so this is the one
    // place the television invariant has to hold.
    _ensureRemoteInChrome();
  }

  /// Whether the player chrome — timeline, transport, top-right menus — may be
  /// on screen. Single decision point so nothing slips through while an end
  /// card is up; only the back button survives it.
  bool get _controlsVisible => _showControls && !_endCardVisible;

  /// Netflix-style: hide the cursor while controls are hidden during playback.
  /// Never on an end card, which has buttons to aim at.
  bool get _shouldHideCursor =>
      !_showControls &&
      !_endCardVisible &&
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
    final session = _playerController.session;
    final next = (session.volume + delta).clamp(0.0, 100.0);
    session.setVolume(next);
    _showControlsTransient();
    _safeSetState(() {});
  }

  /// Whether the remote is currently walking the on-screen controls rather than
  /// driving playback.
  ///
  /// A television has exactly four direction keys and they have to do two jobs:
  /// scrub the film, and move between the buttons on the HUD. Which job they do
  /// is decided by who holds the focus. The player itself holds it by default,
  /// so arrows scrub — what a remote should do the moment a film is on.
  /// Pressing OK hands the focus to the control bar; from there the same arrows
  /// walk the buttons, and Back hands it straight back.
  bool get _remoteBrowsingControls =>
      TvMode.isTv &&
      // `hasFocus` and not merely "the player is not primary": the chrome
      // lives inside this node, so a button holding the focus keeps the
      // subtree focused. Focus that has escaped the subtree altogether is a
      // different state, and treating it as "browsing the controls" is what
      // used to wedge the chrome on screen forever.
      _keyboardFocusNode.hasFocus &&
      !_keyboardFocusNode.hasPrimaryFocus;

  /// Keeps the player holding the focus whenever nothing else legitimately is.
  ///
  /// The chrome's buttons are inside [_keyboardFocusNode], so a remote sitting
  /// on one still routes its keys through here. What has to be caught is the
  /// focus leaving the subtree: the chrome faded out from under it, a panel
  /// closed, a popup went away. From there the arrows reach nothing at all and
  /// the player looks frozen. A popup on the overlay is the one legitimate
  /// reason for the focus to be somewhere else.
  void _handlePlayerFocusChanged() {
    if (_isDisposing || !mounted) return;
    // Not while this screen is on its way out, either: the screen coming up
    // underneath is taking the focus, and it is right to let it. Asked of the
    // widget tree instead — `ModalRoute.of` from here is an ancestor lookup on
    // an element that may already be deactivated, which throws.
    if (!_keyboardFocusNode.hasFocus && _openPopup == null && !_isLeaving) {
      _keyboardFocusNode.requestFocus();
      // On a television the player node is a parking spot, not a destination.
      // If the chrome is up — a menu just closed over it, a panel went away —
      // the remote belongs on a control, outlined, and not sitting invisibly
      // on the video with the arrows doing something else.
      _ensureRemoteInChrome();
      return;
    }
    // Read all over the build, and it just changed.
    _safeSetState(() {});
  }

  /// Hands the remote to the control bar, and puts the chrome up to receive it.
  void _enterControlBar() => _showControlsTransient();

  /// The invariant that makes the remote legible: on a television, chrome on
  /// screen means something on it is outlined.
  ///
  /// The player used to keep the focus for itself while the HUD was up, which
  /// gave two indistinguishable states — same picture, same bar, but in one of
  /// them nothing was highlighted and the arrows scrubbed, and in the other a
  /// button was highlighted and the arrows walked. Which one you were in
  /// depended on whether the HUD had been woken by OK or by a seek. This
  /// collapses them into one: the HUD is up, the scrubber is outlined, left and
  /// right seek from it.
  void _ensureRemoteInChrome() {
    if (!TvMode.isTv) return;
    if (_isDisposing || _isLeaving || !_showControls) return;
    // A popup, the episode browser or an end card owns the focus while it is
    // up, and taking it back would trap the remote behind them.
    if (_openPopup != null || _showEpisodesPanel || _endCardVisible) return;

    // After the frame: a hidden chrome excludes its own controls from focus,
    // so until it is painted there is nothing for the focus to land on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposing || _isLeaving) return;
      if (!_showControls || _openPopup != null || _showEpisodesPanel) return;
      // Already standing on a control — including one the user walked to.
      // Re-requesting would drag them back to the scrubber on every seek.
      if (_remoteBrowsingControls) return;
      if (_progressFocusNode.context != null) {
        _progressFocusNode.requestFocus();
        return;
      }
      // Chromes with no scrubber node of their own fall back to play/pause,
      // then to whatever traversal reaches first.
      if (_playPauseFocusNode.context != null) {
        _playPauseFocusNode.requestFocus();
        return;
      }
      _keyboardFocusNode.nextFocus();
    });
  }

  /// Takes the remote back off the control bar.
  void _leaveControlBar() {
    _keyboardFocusNode.requestFocus();
    setState(() => _showControls = false);
  }

  KeyEventResult _handlePlayerKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isInitialized || _isDisposing) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final mediaResult = _mediaKeys.handleKeyboardEvent(event);
    if (mediaResult != null) return mediaResult;

    final key = event.logicalKey;
    final browsingControls = _remoteBrowsingControls;

    // Any key pressed while the remote is on the control bar means the user is
    // there, so the hide countdown starts over — the same thing a mouse move
    // does for a pointer. Without it the bar would fade out mid-navigation.
    if (browsingControls) _hideControlsWithDelay();

    // OK / D-pad centre / controller A. Space keeps its own branch below,
    // because a keyboard user expects it to be play-pause and nothing else.
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      // A focused button answers for itself — the app-wide shortcut turns this
      // very key into its activation.
      if (browsingControls) return KeyEventResult.ignored;
      // On a television OK never toggles playback from here: it wakes the HUD
      // and hands the remote to the scrubber, which answers the next OK with
      // play/pause. Reaching this branch with the HUD already up means the
      // focus slipped, and putting it back is the repair.
      if (TvMode.isTv) {
        _enterControlBar();
      } else {
        _togglePlayPause();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      _togglePlayPause();
      return KeyEventResult.handled;
    }

    // While the remote is on the control bar the arrows belong to focus
    // traversal, or the buttons would be unreachable.
    final isArrow = key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;

    if (!browsingControls && isArrow) {
      // A television never scrubs blind. Any direction wakes the HUD and puts
      // the outline on the scrubber; from there the very same key seeks — and
      // now the screen shows what it is seeking. Volume is untouched in either
      // direction: the set owns it and its remote has the keys for it.
      if (TvMode.isTv) {
        // Held down, the wake-up press must not queue forty more of itself.
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        _enterControlBar();
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

      _adjustVolume(
        key == LogicalKeyboardKey.arrowUp ? _volumeStep : -_volumeStep,
      );
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      // Innermost first: a menu opened from the chrome, then the episode
      // panel, then the control bar, and only then the player itself.
      if (_dismissTopPopup()) return KeyEventResult.handled;
      if (_showEpisodesPanel) {
        _closeEpisodesPanel();
        return KeyEventResult.handled;
      }
      if (browsingControls) {
        _leaveControlBar();
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

  /// How much of the screen the video keeps. It gives way to an end card
  /// without ever being hidden: the credits stay visible and playing.
  double get _videoScale => _endCardVisible ? 0.34 : 1.0;

  /// Puts away whichever end card is up. Both are dismissed the same ways —
  /// the close button, and a tap on the video the card shrank.
  void _dismissEndCard() {
    final nav = _episodeNav;
    if (nav == null) return;
    if (nav.showUpcomingEpisodeCard) {
      nav.dismissUpcomingEpisodeCard();
      return;
    }
    nav.dismissNextSeasonCard();
  }

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
    _isLeaving = true;
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

  Future<void> _leavePlayer() {
    // Tout de suite, pas à la destruction de l'écran : celle-ci n'arrive qu'une
    // fois l'animation de sortie terminée, et jusque-là le film continuerait de
    // s'entendre par-dessus l'écran qu'on rejoint.
    //
    // `stop` plutôt que `pause` : c'est là que le décodeur matériel est rendu,
    // et c'est la partie chère du démontage. La payer maintenant la fait tomber
    // pendant l'animation, au lieu de figer l'écran d'arrivée. La position et
    // la durée envoyées au serveur sont celles que le contrôleur a en mémoire,
    // pas celles du moteur — l'arrêter d'abord ne les perd pas.
    unawaited(_playerController.session.stop());
    _safeSetState(() => _isLeaving = true);
    return _syncProgressOnExit(popAfter: true);
  }

  @override
  void dispose() {
    _isDisposing = true;
    // A menu belongs to the app's overlay, not to this route: left open, it
    // would still be on screen after the player is gone.
    _dismissTopPopup();
    unawaited(_mediaKeys.detach());
    _keyboardFocusNode.removeListener(_handlePlayerFocusChanged);
    _keyboardFocusNode.dispose();
    _playPauseFocusNode.dispose();
    _progressFocusNode.dispose();
    _popupFocusScope.dispose();
    _controlsTimer?.cancel();
    _startupWatchdog?.cancel();
    _zoomHintTimer?.cancel();
    _seekHintTimer?.cancel();
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
    if (!_isEpisodeTransition && _ownsDeviceOrientation) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    // Not between two episodes: the next screen is already built and holding
    // the same override, and dropping it here would flash the panel back to
    // the system brightness in the middle of a series.
    if (!_isEpisodeTransition) {
      unawaited(ScreenBrightnessControl.release());
    }
    if (_episodeNav != null && _episodeNavListener != null) {
      _episodeNav!.removeListener(_episodeNavListener!);
    }
    _episodeNav?.dispose();
    _playerController.dispose();
    super.dispose();
  }

  /// Keeps a chrome layer clear of the screen's cutouts — the camera bubble,
  /// a notch.
  ///
  /// Only the chrome. The picture stays full-bleed: it is what the user came
  /// for, and a black band down the side of the film would cost far more than
  /// a button sitting a few pixels in.
  ///
  /// This is the blunt version, and it is only for the layers that place their
  /// controls freely — a Studio layout puts a button at any fraction of the
  /// screen, so there is no row to test and nothing finer to do than pad the
  /// edge. The Emby chrome takes the cutouts themselves and moves one row at a
  /// time; see its `cutouts`.
  Widget _clearOfCutout(Widget chrome) => Padding(
        padding: DisplayCutouts.of(context),
        child: chrome,
      );

  void _updateVideoFit(BoxFit fit) {
    // La surface est reconstruite avec le nouveau cadrage ; chaque moteur
    // l'applique à sa façon — Flutter met une texture à l'échelle, la vue
    // native se redimensionne elle-même.
    setState(() => _videoFit = fit);
  }

  void _syncSubtitlePadding(BuildContext context) {
    if (!mounted || !_isInitialized) return;

    final chrome = _resolveChrome(
        Provider.of<PlayerLayoutProvider>(context, listen: false));
    final screenSize = MediaQuery.sizeOf(context);
    final measuredTop = _measureTimelineTop(context);
    final padding = SubtitlePaddingCalculator.resolve(
      controlsVisible: _showControls,
      useModularLayout: chrome.useModular,
      modularConfig: chrome.config,
      screenSize: screenSize,
      measuredTimelineTopDy: measuredTop,
    );

    if (padding == _lastSubtitlePadding) return;
    _lastSubtitlePadding = padding;

    _playerController.session.setSubtitlePadding(
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

  /// Puts a popup on the overlay and gives a remote a way in and out of it.
  ///
  /// An [OverlayEntry] is not a route: nothing moves the focus into it, and
  /// Back does not close it. On a television that leaves every menu the chrome
  /// opens unreachable, and leaves Back meaning "quit the film" while a menu is
  /// still on screen. So the content is wrapped in a focus scope the remote is
  /// walked into, and the dismissal is registered where the player's own Back
  /// handling can find it.
  ///
  /// [builder] receives the dismissal to wire into its barrier and its close
  /// button, in place of calling `entry.remove()` itself — going through it is
  /// what keeps the focus and the registration in step.
  void _insertPlayerPopup(Widget Function(VoidCallback dismiss) builder) {
    // Never two at once; the one underneath could not be reached anyway.
    _dismissTopPopup();

    late final OverlayEntry entry;
    var dismissed = false;

    void dismiss() {
      if (dismissed) return;
      dismissed = true;
      if (identical(_openPopup?.entry, entry)) _openPopup = null;
      entry.remove();
      if (_isDisposing || !mounted) return;
      // The remote came from the control bar and has to go back to it, or the
      // next key press has nowhere to land.
      if (TvMode.isTv) {
        _enterControlBar();
      } else {
        _keyboardFocusNode.requestFocus();
      }
    }

    entry = OverlayEntry(
      builder: (ctx) => FocusScope(
        node: _popupFocusScope,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape ||
              key == LogicalKeyboardKey.goBack ||
              key == LogicalKeyboardKey.browserBack) {
            dismiss();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: builder(dismiss),
      ),
    );

    _openPopup = (entry: entry, dismiss: dismiss);
    Overlay.of(context).insert(entry);

    // Only a remote is walked in: on a desktop the pointer is already where
    // the user is looking, and stealing the focus would move it away.
    if (!TvMode.isTv) return;
    // After the frame — the scope has no children to offer until the entry
    // has been built at least once.
    //
    // The first focusable it finds is a floor, not a verdict: a menu knows
    // better than this method where its remote belongs — the track being
    // played, the row it was opened from — and says so from its own
    // post-frame callback, registered during the build this one waits for and
    // therefore running after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (dismissed || !mounted || _isDisposing) return;
      _popupFocusScope.requestFocus();
      _popupFocusScope.nextFocus();
    });
  }

  /// Closes the popup on screen, if there is one. Returns whether it did, so
  /// Back can stop there instead of also acting on the player.
  bool _dismissTopPopup() {
    final popup = _openPopup;
    if (popup == null) return false;
    popup.dismiss();
    return true;
  }

  void _showTrackSettings({int initialTabIndex = 0}) {
    final renderBox =
        _settingsButtonKey.currentContext?.findRenderObject() as RenderBox?;
    // Fallback: center the panel when the settings button isn't on-canvas.
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

    _insertPlayerPopup(
      (dismiss) => GestureDetector(
        onTap: dismiss,
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
                      session: _playerController.session,
                      currentFit: _videoFit,
                      onFitChanged: _updateVideoFit,
                      onClose: dismiss,
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
  }

  /// Emby-chrome settings menu, anchored to the button that opened it.
  void _showEmbySettingsMenu({
    EmbyMenuSection section = EmbyMenuSection.root,
    required GlobalKey anchorKey,
  }) {
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

    _insertPlayerPopup(
      (dismiss) => GestureDetector(
        onTap: dismiss,
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
                      session: _playerController.session,
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
                      onClose: dismiss,
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

  Future<void> _setPlaybackRate(double rate) async {
    await _playerController.session.setRate(rate);
    if (!mounted) return;
    setState(() => _playbackRate = rate);
    _showControlsTransient();
  }

  Future<void> _cyclePlaybackRate() async {
    final idx = _playbackRates.indexOf(_playbackRate);
    final next = _playbackRates[(idx < 0 ? 0 : idx + 1) % _playbackRates.length];
    await _playerController.session.setRate(next);
    if (!mounted) return;
    setState(() => _playbackRate = next);
    _showControlsTransient();
  }

  /// Only where two fingers can reach the picture: a television is driven by a
  /// remote and a desktop by a mouse, and neither can produce this gesture.
  bool get _pinchToZoomEnabled => AppPlatform.isMobile && !TvMode.isTv;

  void _handleVideoScaleStart(ScaleStartDetails details) {
    _pinchResolved = false;
  }

  void _handleVideoScaleUpdate(ScaleUpdateDetails details) {
    if (_pinchResolved) return;
    final next = PinchZoomFit.resolve(
      scale: details.scale,
      pointerCount: details.pointerCount,
    );
    if (next == null) return;
    _pinchResolved = true;
    if (next != _videoFit) _updateVideoFit(next);
    // Shown even when the fit does not change, so pinching a picture that
    // already fills the screen answers instead of doing nothing at all.
    _showZoomHint(next);
  }

  void _showZoomHint(BoxFit fit) {
    _zoomHintTimer?.cancel();
    setState(() {
      _zoomHintFit = fit;
      _zoomHintVisible = true;
      _zoomHintMounted = true;
    });
    _zoomHintTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted || _isDisposing) return;
      setState(() => _zoomHintVisible = false);
      // Taken out of the tree only once it has finished fading, so the blur
      // layer is not paid for over the rest of the film.
      _zoomHintTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted || _isDisposing) return;
        setState(() => _zoomHintMounted = false);
      });
    });
  }

  /// A double-tap on one of the side zones: move the film, and say so.
  ///
  /// Separate from [_seekRelative] because the two have different audiences.
  /// The ±10 buttons and the media keys are already visible causes with a
  /// visible chrome to read the result off; a double-tap has neither, and is
  /// the only seek that can arrive several times in a second.
  void _handleDoubleTapSeek(int seconds) {
    _seekRelative(seconds);
    _showSeekHint(seconds);
  }

  void _showSeekHint(int seconds) {
    final forward = seconds > 0;
    _seekHintTimer?.cancel();
    setState(() {
      // A burst only accumulates while it keeps going the same way. Tapping
      // back after tapping forward starts a new count, because "30 s" would
      // otherwise be describing a journey that ended 10 s from where it began.
      _seekHintSeconds =
          (_seekHintVisible && forward == _seekHintForward)
              ? _seekHintSeconds + seconds.abs()
              : seconds.abs();
      _seekHintForward = forward;
      _seekHintPulse++;
      _seekHintVisible = true;
      _seekHintMounted = true;
    });
    _seekHintTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || _isDisposing) return;
      setState(() => _seekHintVisible = false);
      // Out of the tree once faded, so its ticker is not left running over the
      // rest of the film.
      _seekHintTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted || _isDisposing) return;
        setState(() => _seekHintMounted = false);
      });
    });
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

    _insertPlayerPopup(
      (dismiss) => GestureDetector(
        onTap: dismiss,
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
                      session: _playerController.session,
                      playerController: _playerController,
                      onClose: dismiss,
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
    return (_playerController.session.bufferedAhead.inSeconds / total)
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

    _insertPlayerPopup(
      (dismiss) => GestureDetector(
        onTap: dismiss,
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
                        dismiss();
                        _playerController.seekToAbsoluteSeconds(0);
                      },
                      onClose: dismiss,
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
    final chrome = _resolveChrome(layoutProvider);
    final isTv = TvScope.of(context);
    // A fixed chrome is its own thing: it is neither the default HUD nor the
    // modular layer, and it ignores the layout config entirely.
    //
    // A television always gets one, whatever playeur the account selected. The
    // modular layouts place their controls in percentages of the screen, for a
    // pointer that can reach any of them directly; a D-pad walks between them,
    // and no arrangement a user can draw guarantees a path that reaches every
    // control. The fixed chrome is laid out for that walk.
    final fixedChrome = isTv ? FixedChromeId.emby : chrome.fixedChrome;
    final useModular = fixedChrome == null && chrome.useModular;
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
          // The remote's Back arrives here, not as a key event — and it has to
          // unwind the same stack the key path does, innermost first, or it
          // walks out of the film with a menu still open on top of it.
          if (_dismissTopPopup()) return;
          if (_showEpisodesPanel) {
            _closeEpisodesPanel();
            return;
          }
          // On the control bar Back means "put that away", not "leave".
          if (_remoteBrowsingControls) {
            _leaveControlBar();
            return;
          }
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
                        // Only while the card has actually shrunk the picture.
                        // At full size the radius is 0, so this clips a
                        // rectangle to itself — an antialiased full-screen clip
                        // over every decoded frame, for nothing. It is free to
                        // skip on a desktop GPU and it is not free on a stick.
                        clipBehavior:
                            _videoScale < 1 ? Clip.antiAlias : Clip.none,
                        animateColor: false,
                        child: SizedBox.expand(
                          // Le widget de rendu appartient au moteur : mpv
                          // dessine dans une texture, ExoPlayer dans une
                          // SurfaceView composée par le plan vidéo de l'écran.
                          //
                          // Retiré dès qu'on s'en va. Une SurfaceView est une
                          // couche du système : Flutter ne peut pas l'emmener
                          // dans son animation de sortie, et elle y restait
                          // figée sur sa dernière image pendant que le reste
                          // glissait. Du noir s'anime, lui.
                          child: _isLeaving
                              ? const ColoredBox(color: Colors.black)
                              : _playerController.session.buildSurface(
                                  fit: _videoFit,
                                  aspectRatio:
                                      _playerController.videoAspectRatio,
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
                // A pinch spans two of the tap zones below, so it cannot be
                // handled by them: the recognizer has to sit above all three,
                // where both fingers land on the same detector. The zones keep
                // their taps — a scale gesture only takes the arena once the
                // fingers move, which is past the point where a tap is still
                // possible.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.deferToChild,
                    // Left null off a touchscreen so no scale recognizer joins
                    // the arena there at all.
                    onScaleStart:
                        _pinchToZoomEnabled ? _handleVideoScaleStart : null,
                    onScaleUpdate:
                        _pinchToZoomEnabled ? _handleVideoScaleUpdate : null,
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onDoubleTap: () => _handleDoubleTapSeek(-10),
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
                            onDoubleTap: () => _handleDoubleTapSeek(10),
                            onTap: _handleVideoTap,
                            child: Container(color: Colors.transparent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_seekHintMounted)
                  Positioned.fill(
                    child: SeekFeedbackOverlay(
                      forward: _seekHintForward,
                      seconds: _seekHintSeconds,
                      pulse: _seekHintPulse,
                      visible: _seekHintVisible,
                    ),
                  ),
                if (_zoomHintMounted)
                  Positioned.fill(
                    child: VideoZoomHint(
                      fit: _zoomHintFit,
                      visible: _zoomHintVisible,
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
                    volume: _playerController.session.volume,
                    onVolumeChanged: (v) =>
                        _playerController.session.setVolume(v),
                    brightness: _screenBrightness,
                    onBrightnessChanged: _setScreenBrightness,
                    onBrightnessDraggingChanged: (dragging) {
                      // Same deal as the scrubber: the chrome cannot fade out
                      // from under a finger that is still on it.
                      if (dragging) {
                        _controlsTimer?.cancel();
                        _safeSetState(() => _showControls = true);
                      } else {
                        _hideControlsWithDelay();
                      }
                    },
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
                    isTv: isTv,
                    playPauseFocusNode: _playPauseFocusNode,
                    progressFocusNode: _progressFocusNode,
                    // Row by row, and only the rows the camera is actually
                    // on. Padding the layer would have stepped the whole
                    // interface aside for something in the way of one control.
                    cutouts: DisplayCutouts.rects(context),
                  ),
                  }
                else if (useModular) ...[
                  _clearOfCutout(ModularControlsLayer(
                    config: chrome.config,
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
                    volume: _playerController.session.volume,
                    onVolumeChanged: (v) =>
                        _playerController.session.setVolume(v),
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
                  )),
                ] else
                  _clearOfCutout(PlayerHUDOverlay(
                    visible: _controlsVisible,
                    timelineAnchorKey: _timelineAnchorKey,
                    session: _playerController.session,
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
                      await _playerController.session.setExactSeek(false);
                    },
                    onSliderChanged: (value) {
                      _playerController.dragValue = value;
                      // Scrub live only where the session can already serve the
                      // frame; dragging past that would stall mpv on segments
                      // that do not exist yet. The final position is committed
                      // in onSliderChangeEnd.
                      if (_playerController.canSeekWithinSession(value.toInt())) {
                        _playerController.session.seek(Duration(
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
                        await _playerController.session.setExactSeek(true);
                      }
                      _hideControlsWithDelay();
                    },
                    onNextEpisode: (_episodeNav?.nextEpisode != null)
                        ? _goToNextEpisode
                        : null,
                  )),
                if (_controlsVisible && useDefaultHud)
                  _clearOfCutout(TopRightControls(
                    session: _playerController.session,
                    currentFit: _videoFit,
                    onFitChanged: _updateVideoFit,
                    playerController: _playerController,
                    episodeNav: _episodeNav,
                    onSeekToAbsolute: _playerController.seekToAbsoluteSeconds,
                  )),
                // Overlays must be AFTER HUD in Stack to render on top.
                // If the Studio layout already places a skip-intro control —
                // or the fixed chrome draws its own — hide the built-in
                // overlay to avoid a duplicate CTA.
                if ((_episodeNav?.showSkipIntro ?? false) &&
                    fixedChrome == null &&
                    !(useModular &&
                        chrome.config.hasControl(PlayerControlType.skipIntro)))
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
                    !_endCardVisible)
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
                if (_endCardVisible)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: 0,
                    width: MediaQuery.of(context).size.width * _videoScale,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _dismissEndCard,
                      ),
                    ),
                  ),
                // The only chrome that survives an end card: without it the
                // page would be a dead end, since every other way out is
                // hidden.
                if (_endCardVisible)
                  Positioned(
                    top: macOSWindowControlsTopInset + 12,
                    left: 20,
                    child: _PlayerBackButton(onTap: _leavePlayer),
                  ),
                if (_episodeNav?.showUpcomingEpisodeCard ?? false)
                  UpcomingEpisodeOverlay(
                    episode: _episodeNav!.upcomingEpisode!,
                    onDismiss: () =>
                        _episodeNav!.dismissUpcomingEpisodeCard(),
                    onPlayNext: _episodeNav?.nextEpisode != null
                        ? _goToNextEpisode
                        : null,
                    videoInset:
                        MediaQuery.of(context).size.width * _videoScale,
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
                //
                // Past the deadline it stops being a spinner and starts being a
                // question, which does take input — there is a button on it.
                if (!_playerController.hasFirstFrame)
                  if (_startupStalled)
                    Positioned.fill(
                      child: _StalledStartup(
                        onRetry: _retryPlayback,
                        onBack: _leavePlayer,
                      ),
                    )
                  else
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

/// What replaces the start-up spinner once the picture is overdue.
///
/// The spinner is honest for twenty-five seconds and a lie after that: it says
/// "working on it" about a start-up that, by then, has usually stopped working
/// on anything. What actually helps is naming the likeliest cause — the link
/// between this screen and the server — and offering the one action that fixes
/// most of them, which is to open the whole thing again from scratch.
class _StalledStartup extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onBack;

  const _StalledStartup({required this.onRetry, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.86),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.wifi_tethering_error_rounded,
                size: 54,
                color: Colors.white70,
              ),
              const SizedBox(height: 22),
              const Text(
                'La lecture ne démarre pas',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Le serveur met trop longtemps à envoyer la vidéo. '
                'C’est presque toujours le réseau entre cet appareil et lui — '
                'réessayer suffit le plus souvent.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    // The remote lands here: it is the button that helps.
                    autofocus: true,
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Réessayer'),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: onBack,
                    child: const Text('Retour'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// Le playeur retenu pour une lecture : sa configuration, et laquelle des trois
/// couches de chrome elle décrit.
///
/// [fixedChrome] n'est pas un troisième champ mais une lecture de la
/// configuration : un chrome figé *est* une configuration qui en nomme un.
class _ResolvedChrome {
  final PlayerLayoutConfig config;
  final bool useModular;

  const _ResolvedChrome({required this.config, required this.useModular});

  FixedChromeId? get fixedChrome => config.fixedChrome;
}
