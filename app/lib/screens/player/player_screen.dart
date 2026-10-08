import '../../services/playback_access.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../utils/app_platform.dart';
import '../../utils/window_controls.dart';
import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../../navigation/search_route_observer.dart';
import '../../services/api_client.dart';
import '../../services/download_manager.dart';
import '../../services/server_reachability.dart';
import '../../services/media_details_cache.dart';
import '../../services/picture_in_picture.dart';
import '../../services/player_presence.dart';
import '../../services/screen_brightness_control.dart';
import '../../services/watch_party.dart';
import 'chrome_auto_hide.dart';
import 'display_cutouts.dart';
import 'video_fit.dart';
import '../../tv/tv_mode.dart';
import '../../tv/touchpad_motion.dart';
import '../../tv/tv_touchpad.dart';
import '../../utils/poster_url.dart';
import 'hooks/use_episodes_panel.dart';
import 'hooks/use_gesture_hints.dart';
import 'hooks/use_playback_handoff.dart';
import 'hooks/use_player_controller.dart';
import 'hooks/use_episode_navigation.dart';
import 'hooks/use_player_media_keys.dart';
import 'hooks/use_player_popup.dart';
import 'hooks/use_player_watch_party.dart';
import 'widgets/seek_feedback_overlay.dart';
import 'widgets/video_zoom_hint.dart';
import 'widgets/next_episode_overlay.dart';
import 'widgets/next_season_overlay.dart';
import 'widgets/upcoming_episode_overlay.dart';
import 'widgets/onyx/onyx_controls_layer.dart';
import 'widgets/onyx/onyx_settings_menu.dart';
import 'widgets/player_episodes_panel.dart';
import 'widgets/player_popups.dart';
import 'widgets/player_screen_lock.dart';
import 'widgets/player_status_panels.dart';
import 'widgets/player_tap_zones.dart';
import 'widgets/player_video_stage.dart';
import 'widgets/still_watching_prompt.dart';
import 'widgets/watch_party_overlay.dart';
import 'playback/live_subtitles.dart';
import 'playback/relay_trigger.dart';
import 'playback/remote_seek.dart';
import 'playback/sleep_timer.dart';
import 'playback/still_watching.dart';
import 'pinch_zoom_fit.dart';
import 'player_key_routing.dart';
import 'player_media_info.dart';
import 'subtitle_padding.dart';
import 'player_playback_preferences.dart';
import 'player_shortcuts.dart';
import '../../desktop_window.dart';
import '../../utils/watched_verdict.dart';
import '../../l10n/tr.dart';

// L'écran du lecteur est découpé par sujet. Ce fichier garde l'état, son
// cycle de vie et la construction de l'arbre ; les comportements sont dans
// des extensions sur cet état, une par sujet. Voir ADR-0052.
part 'player_screen_chrome.dart';
part 'player_screen_flow.dart';
part 'player_screen_remote.dart';
part 'player_screen_startup.dart';

class PlayerScreen extends StatefulWidget {
  final dynamic media; // Can be Media or HomeMediaItem
  final PlayerPlaybackPreferences? inheritedPreferences;
  final bool autoAdvance;
  final BoxFit? initialVideoFit;
  final int? seasonNumber;
  final int? resumeAtSeconds;
  final bool startPaused;
  final Map<String, DateTime> relayAttempts;

  const PlayerScreen({
    super.key,
    required this.media,
    this.inheritedPreferences,
    this.autoAdvance = false,
    this.initialVideoFit,
    this.seasonNumber,
    this.resumeAtSeconds,
    this.startPaused = false,
    this.relayAttempts = const {},
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerController _playerController;
  late final PlayerMediaInfo _info =
      PlayerMediaInfo(widget.media as Object, seasonNumber: widget.seasonNumber);
  EpisodeNavigationController? _episodeNav;
  late final EpisodesPanelController _episodesPanel;
  late final PlaybackHandoffWatch _handoff;
  late final PlayerWatchParty _party;
  final GestureHints _hints = GestureHints();
  final PinchTracker _pinch = PinchTracker();
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

  /// True from the moment this screen starts leaving — a pop, or a jump to the
  /// next episode. The focus is on its way to another screen from here on, and
  /// this one must stop claiming it back.
  bool _isLeaving = false;
  bool _progressFlushed = false;

  /// Le lecteur a été quitté pendant le générique de fin, pour l'épisode
  /// suivant ou pour de bon : l'épisode compte comme vu, même sous le seuil.
  /// Voir [countsAsWatched].
  bool _leftDuringCredits = false;
  ApiClient? _apiClient;
  Timer? _relayTimer;

  /// Quand le relais peut seulement s'envisager. Voir [RelayTrigger].
  final RelayTrigger _relayTrigger = RelayTrigger();
  bool _findingRelay = false;
  bool _wantsPlayback = true;
  String? _sourceAccountId;
  int _resumePosition = 0;

  /// How the video is fitted inside the player viewport.
  /// [BoxFit.contain] = original (letterbox possible).
  /// [BoxFit.cover]   = adaptive (fills screen, may crop edges).
  BoxFit _videoFit = BoxFit.contain;

  /// True while the film is playing in the system's little window, over
  /// whatever the phone is doing instead.
  ///
  /// The chrome is not drawn there — a window that size has no room for it, and
  /// nothing to tap it with — so the player renders the picture and nothing
  /// else until it comes back.
  bool _inPip = false;

  /// L'écran est verrouillé contre les touchers : plus de chrome, plus de
  /// gestes, jusqu'à l'appui long sur le cadenas. Voir [PlayerScreenLock].
  bool _screenLocked = false;

  /// « Vous regardez encore ? » est à l'écran : la lecture est en pause et
  /// n'en sort que par une réponse. Voir [StillWatching].
  bool _stillWatchingAsked = false;
  final GlobalKey<PlayerScreenLockState> _screenLockKey = GlobalKey();

  /// The shape last handed to the system, as a thousandth of the aspect ratio.
  /// Kept so the arming call is made when it changes and not four times a
  /// second for the life of the film.
  int _armedShape = 0;

  /// Screen brightness override, 0.0 -> 1.0, or null on a screen whose
  /// backlight this app does not drive. Null is what keeps the left-hand bar
  /// out of the chrome everywhere except a phone or tablet.
  double? _screenBrightness;

  /// When the last side-zone seek landed; see [_handleSideZoneTap].
  DateTime? _lastSideSeekAt;
  static const _sideSeekBurstWindow = Duration(milliseconds: 1000);

  /// Playback rate cycle for the speed control.
  double _playbackRate = 1.0;
  static const _playbackRates = [0.75, 1.0, 1.25, 1.5, 2.0];

  /// Key attached to the settings button so we can anchor the popup above it.
  final GlobalKey _settingsButtonKey = GlobalKey();

  /// Key attached to the subtitles button so we can anchor the popup above it.
  final GlobalKey _subtitlesButtonKey = GlobalKey();

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

  /// The scrubber — where the remote lands when it came in seeking.
  ///
  /// Left and right with the HUD down seek straight away, and
  /// put the outline on the bar so the next press goes on seeking from it with
  /// the screen saying so. OK on the bar itself toggles playback.
  final FocusNode _progressFocusNode = FocusNode(debugLabel: 'player-progress');

  /// Which control the remote is handed the next time the HUD comes up: the
  /// scrubber when it arrived with a seek, play/pause otherwise.
  _RemoteEntry _remoteEntry = _RemoteEntry.playPause;

  /// Where a run of remote seeks is heading, before it is committed — see
  /// [RemoteSeek].
  late final RemoteSeek _remoteSeek = RemoteSeek(onCommit: (target) {
    if (!mounted || _isDisposing) return;
    _seekTo(target);
    _safeSetState(() {});
  });

  /// Les menus ouverts par-dessus le lecteur. Voir [PlayerPopupHost].
  late final PlayerPopupHost _popups = PlayerPopupHost(
    isActive: () => !_isDisposing && mounted,
    onDismissed: () {
      // The remote came from the control bar and has to go back to it, or the
      // next key press has nowhere to land.
      if (TvMode.isTv) {
        _enterControlBar();
      } else {
        _keyboardFocusNode.requestFocus();
        // Le chrome est resté affiché tout le temps du menu (voir
        // [chromeMayAutoHide]) : son compte à rebours repart d'ici.
        if (_showControls) _hideControlsWithDelay();
      }
    },
  );

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

  /// Mouse moved over the video: see [_handlePointerHover].
  static const Duration _hoverRearmInterval = Duration(milliseconds: 200);
  DateTime? _lastHoverRearm;

  String? _mediaLogoUrl;
  bool _requestingNextSeason = false;

  /// How big the fixed chrome is drawn.
  ///
  /// The same widget at the same width reads slightly larger on an iPhone than
  /// on an Android phone, so it is trimmed there. Only what is drawn: the
  /// targets stay the size of a finger.
  static const double _iosChromeScale = 0.9;

  double get _chromeScale => AppPlatform.isIOS ? _iosChromeScale : 1;

  /// `setState`, pour les extensions de cet état qui ne peuvent pas
  /// l'appeler elles-mêmes (le membre est protégé).
  void _update(VoidCallback fn) => setState(fn);

  void _safeSetState(VoidCallback fn) {
    if (_isDisposing || !mounted) return;
    try {
      setState(fn);
    } on Object {
      // Widget disposed between check and call
    }
  }

  void _rebuild() => _safeSetState(() {});

  @override
  void initState() {
    super.initState();
    PlayerPresence.enter();
    TvTouchpad.addMoveListener(_handleTouchpadMove);
    _showControls = !widget.autoAdvance;
    _wantsPlayback = !widget.startPaused;
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
    PictureInPicture.active.addListener(_handlePictureInPictureChanged);
    PictureInPicture.closed.addListener(_handlePictureInPictureClosed);
    _keyboardFocusNode.addListener(_handlePlayerFocusChanged);
    _hints.addListener(_rebuild);
    SleepTimer.instance.retain();
    StillWatching.instance.retain();
    SleepTimer.instance.addListener(_applySleepTimer);
    _playerController = PlayerController()
      ..onQualityAdapted = (tier) => _party.showNotice(
          tr('Connexion lente : qualité réduite à {0}', [tier.label]));
    _party = PlayerWatchParty(
      controller: _playerController,
      api: () => _apiClient,
      // Une installation sans carnet de comptes n'a pas d'identifiant : la
      // séance n'en dépend pas.
      accountKey: () => _sourceAccountId ?? WatchPartySession.defaultAccountKey,
      mediaId: () => _info.media.id,
      isGone: () => _isLeaving || _isDisposing || !mounted,
      playbackRate: () => _playbackRate,
      setWantsPlayback: (wanted) => _wantsPlayback = wanted,
      openMedia: (media, {required resumeAtSeconds, required startPaused}) =>
          _navigateToEpisode(
            media,
            fromParty: true,
            resumeAtSeconds: resumeAtSeconds,
            startPaused: startPaused,
          ),
    )
      ..addListener(_rebuild)
      ..listen();
    _handoff = PlaybackHandoffWatch(
      api: () => _apiClient,
      controller: _playerController,
      inParty: () => _party.party != null,
      isLeaving: () => _isLeaving || !mounted,
      pause: _pauseByChoice,
      resume: () {
        _wantsPlayback = true;
        if (!_playerController.isPlaying) _playerController.togglePlayPause();
      },
      leave: () => unawaited(_leavePlayer()),
    )..addListener(_rebuild);
    _episodesPanel = EpisodesPanelController(
      api: () => _apiClient,
      currentSeasonId: _info.seasonId,
      currentShowId: _info.showId,
      currentEpisodeId: _info.media.id,
    )..addListener(_rebuild);
    _mediaKeys = PlayerMediaKeysBinding(
      onPlayPause: _togglePlayPause,
      onRewind: () => _seekRelative(-10),
      onFastForward: _handleMediaFastForward,
      isPlaying: () => _playerController.isPlaying,
    );
    _init().catchError((Object error) {
      debugPrint('Player initialization failed: ${redactPlaybackDiagnostic(error)}');
      _safeSetState(() => _startupStalled = true);
    });
  }

  @override
  void dispose() {
    _isDisposing = true;
    PlayerPresence.leave();
    TvTouchpad.removeMoveListener(_handleTouchpadMove);
    // A menu belongs to the app's overlay, not to this route: left open, it
    // would still be on screen after the player is gone.
    _popups.dispose();
    unawaited(_mediaKeys.detach());
    // Disarmed on the way out: the little window is for a film that is playing,
    // and leaving it armed would put the library in a corner of the home
    // screen.
    PictureInPicture.active.removeListener(_handlePictureInPictureChanged);
    PictureInPicture.closed.removeListener(_handlePictureInPictureClosed);
    unawaited(PictureInPicture.disarm());
    _keyboardFocusNode.removeListener(_handlePlayerFocusChanged);
    SleepTimer.instance.removeListener(_applySleepTimer);
    SleepTimer.instance.release();
    StillWatching.instance.release();
    _party.dispose();
    _keyboardFocusNode.dispose();
    _playPauseFocusNode.dispose();
    _progressFocusNode.dispose();
    _controlsTimer?.cancel();
    _startupWatchdog?.cancel();
    _relayTimer?.cancel();
    _handoff.dispose();
    _hints.dispose();
    _episodesPanel.dispose();
    _remoteSeek.dispose();
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

  @override
  Widget build(BuildContext context) {
    final isTv = TvScope.of(context);
    final party = _party.party;
    final nav = _episodeNav;

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handlePlayerKeyEvent,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          await _handleBack();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            cursor:
                _shouldHideCursor ? SystemMouseCursors.none : MouseCursor.defer,
            onHover: (event) => _handlePointerHover(),
            child: Stack(
              children: [
                PlayerVideoStage(
                  scale: _videoScale,
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
                      // Les sous-titres d'une session HLS sont peints
                      // ici, pour tous les moteurs — voir ADR-0031.
                      : LiveSubtitleLayer(
                          feed: _playerController.liveSubtitles,
                          child: _playerController.session.buildSurface(
                            // The chosen framing, drawn the way this
                            // screen wants it — see [VideoFitRendering].
                            fit: VideoFitRendering.resolve(
                              _videoFit,
                              handheld: _handheld,
                              screen: MediaQuery.sizeOf(context),
                            ),
                            aspectRatio: _playerController.videoAspectRatio,
                          ),
                        ),
                ),
                // Everything above the picture, and only when there is room
                // for it.
                //
                // In the system's little window there is none: no chrome, no
                // gestures, no overlays — the picture and the sound, which is
                // what the window is for. Written as one spread rather than a
                // separate tree so the video widget keeps its place in the
                // list: rebuilding it there would tear down the platform view
                // and re-attach the surface, which is a blink in the corner of
                // the home screen for nothing.
                if (!_inPip) ...[
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
                  child: PlayerTapZones(
                    // Only where two fingers can reach the picture: a
                    // television is driven by a remote and a desktop by a
                    // mouse, and neither can produce this gesture.
                    pinch: _handheld ? _pinch : null,
                    onPinchFit: _applyPinchFit,
                    doubleTapTogglesFullscreen: _doubleTapTogglesFullscreen,
                    onDoubleTapFullscreen: _handleDoubleTapFullscreen,
                    onDoubleTapSeek: _handleDoubleTapSeek,
                    onSideTap: _handleSideZoneTap,
                    onCenterTap: () => _handleVideoTap(togglePlayback: true),
                    onWindowDrag:
                        _windowDragEnabled ? () => _startWindowDrag() : null,
                  ),
                ),
                if (_hints.seekMounted)
                  Positioned.fill(
                    child: SeekFeedbackOverlay(
                      forward: _hints.seekForward,
                      seconds: _hints.seekSeconds,
                      pulse: _hints.seekPulse,
                      visible: _hints.seekVisible,
                    ),
                  ),
                if (_hints.zoomMounted)
                  Positioned.fill(
                    child: VideoZoomHint(
                      fit: _hints.zoomFit,
                      visible: _hints.zoomVisible,
                    ),
                  ),
                _buildChrome(isTv),
                // Regarder ensemble : les annonces (« alex a mis en pause ») et
                // l'attente d'un participant qui charge, en haut au centre. Le
                // bouton, lui, est dans la barre du chrome.
                if (party != null || _party.noticeVisible)
                  Positioned(
                    top: macOSWindowControlsTopInset + 20,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Center(
                        child: WatchPartyToast(
                          message: party?.waitingMessage ?? _party.notice,
                          visible: party?.waitingMessage != null ||
                              _party.noticeVisible,
                        ),
                      ),
                    ),
                  ),
                // Overlays must be AFTER the chrome in Stack to render on top.
                // Requires an actual next episode: at the end of a season the
                // pill would otherwise sit there doing nothing when tapped.
                if (nav != null &&
                    nav.showNextEpisodeOutro &&
                    nav.nextEpisode != null &&
                    !_endCardVisible)
                  NextEpisodeOverlay(
                    nextEpisode: nav.nextEpisode,
                    // Pas de compte à rebours vers un épisode que la
                    // minuterie de veille ne laissera pas démarrer.
                    autoPlayActive: nav.outroAutoPlayActive &&
                        !SleepTimer.instance.stopsAfterThisEpisode,
                    frozen: nav.outroAutoPlayFrozen,
                    countdownSeconds: nav.outroCountdownSeconds,
                    onPlayNext: _goToNextEpisode,
                    onCancel: () => nav.cancelAutoPlay(),
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
                    child: PlayerBackButton(onTap: _leavePlayer),
                  ),
                if (nav != null && nav.showUpcomingEpisodeCard)
                  UpcomingEpisodeOverlay(
                    episode: nav.upcomingEpisode!,
                    onDismiss: () => nav.dismissUpcomingEpisodeCard(),
                    onPlayNext:
                        nav.nextEpisode != null ? _goToNextEpisode : null,
                    videoInset:
                        MediaQuery.of(context).size.width * _videoScale,
                  ),
                if (nav != null && nav.showNextSeasonCard)
                  NextSeasonOverlay(
                    season: nav.nextSeason!,
                    submitting: _requestingNextSeason,
                    onRequest: _requestNextSeason,
                    onDismiss: () => nav.dismissNextSeasonCard(),
                    onPlayNext:
                        nav.isSeasonLookahead ? _goToNextEpisode : null,
                    videoInset:
                        MediaQuery.of(context).size.width * _videoScale,
                  ),
                if (_episodesPanel.isOpen && _info.isEpisode)
                  PlayerEpisodesPanel(
                    showTitle: _episodesPanel.showTitle,
                    currentEpisodeId: _info.media.id,
                    seasons: _episodesPanel.seasons,
                    selectedSeasonId: _episodesPanel.selectedSeasonId ??
                        _info.seasonId ??
                        0,
                    onSeasonChanged: (seasonId) =>
                        unawaited(_episodesPanel.selectSeason(seasonId)),
                    episodes: _episodesPanel.episodes,
                    isLoading: _episodesPanel.isLoading,
                    onClose: _closeEpisodesPanel,
                    onEpisodeSelected: _navigateToEpisode,
                  ),
                // Start-up spinner. IgnorePointer like the one below: loading is
                // exactly when the user may want to go back, so the cover must
                // never eat taps meant for the chrome.
                //
                // Past the deadline it stops being a spinner and starts being a
                // question, which does take input — there is a button on it.
                if (!_playerController.hasFirstFrame)
                  if (_startupStalled)
                    Positioned.fill(
                      child: StalledStartup(
                        failure: _playerController.startupFailure,
                        onRetry: _retryPlayback,
                        onBack: _leavePlayer,
                      ),
                    )
                  else
                    const PlayerLoadingSpinner(),
                if (_handoff.handedOffTo != null)
                  Positioned.fill(
                    child: PlayingElsewhere(
                      deviceName: _handoff.handedOffTo!,
                      busy: _handoff.resumingHere,
                      onResume: _handoff.resumeHere,
                      onBack: _leavePlayer,
                    ),
                  ),
                if (_playerController.isSwitchingQuality ||
                    (_playerController.isBuffering && _isInitialized))
                  const PlayerLoadingSpinner(),
                if (_stillWatchingAsked)
                  Positioned.fill(
                    child: StillWatchingPrompt(
                      onContinue: _confirmStillWatching,
                      onLeave: _leavePlayer,
                    ),
                  ),
                // En dernier, donc au-dessus de tout : rien de ce qui précède
                // ne doit pouvoir prendre un doigt tant que l'écran est
                // verrouillé.
                if (_screenLocked)
                  Positioned.fill(
                    child: PlayerScreenLock(
                      key: _screenLockKey,
                      onUnlock: _unlockScreen,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

}

/// Where the remote lands when the player's HUD comes up.
enum _RemoteEntry { playPause, scrubber }
