part of 'player_screen.dart';

/// Ce qui s'affiche par-dessus l'image : le chrome et son compte à rebours,
/// les gestes sur l'image, les menus, la petite fenêtre du système.
extension _PlayerChrome on _PlayerScreenState {
  bool _needsPositionUiRefresh() => _showControls || _episodesPanel.isOpen;

  void _refreshPositionUi({bool force = false}) {
    if (!_needsPositionUiRefresh()) return;

    final now = DateTime.now();
    if (!force &&
        _lastPositionUiRefresh != null &&
        now.difference(_lastPositionUiRefresh!) <
            _PlayerScreenState._positionUiRefreshInterval) {
      return;
    }
    _lastPositionUiRefresh = now;
    _safeSetState(() {});
  }

  /// Hands the system the shape of the film, so it knows what the little
  /// window should look like before the user asks for it.
  ///
  /// Android only lets the window be created at the instant the user leaves —
  /// there is no asking afterwards — so the shape goes over in advance and is
  /// refreshed only when it actually changes.
  void _syncPictureInPicture() {
    if (!PictureInPicture.supported || _isDisposing || _isLeaving) return;
    final aspect = _playerController.videoAspectRatio;
    if (aspect <= 0) return;
    final shape = (aspect * 1000).round();
    if (shape == _armedShape) return;
    _armedShape = shape;
    unawaited(PictureInPicture.arm(width: shape, height: 1000));
  }

  void _handlePictureInPictureChanged() {
    final inPip = PictureInPicture.active.value;
    if (!mounted || _inPip == inPip) return;
    // A menu open when the window shrinks would be most of the window.
    if (inPip) {
      _popups.dismissTop();
      _controlsTimer?.cancel();
    }
    _safeSetState(() {
      _inPip = inPip;
      if (inPip) _showControls = false;
    });
  }

  /// The window was closed rather than restored.
  ///
  /// Pause rather than leave: the activity is already on its way out, and
  /// navigating from under it would be a route change nobody is there to see.
  /// What matters is that a film with nowhere left to play stops playing.
  void _handlePictureInPictureClosed() {
    if (!mounted || !_playerController.isPlaying) return;
    _wantsPlayback = false;
    unawaited(_playerController.session.pause());
  }

  void _scheduleSubtitlePaddingSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSubtitlePadding();
    });
  }

  void _syncSubtitlePadding() {
    if (!mounted || !_isInitialized) return;

    final screenSize = MediaQuery.sizeOf(context);
    final measuredTop = _measureTimelineTop();
    final padding = SubtitlePaddingCalculator.resolve(
      controlsVisible: _showControls,
      screenSize: screenSize,
      measuredTimelineTopDy: measuredTop,
    );

    if (padding == _lastSubtitlePadding) return;
    _lastSubtitlePadding = padding;

    _playerController.session.setSubtitlePadding(
      padding,
      duration: const Duration(milliseconds: 200),
    );
    _playerController.liveSubtitles.setPadding(
      padding,
      duration: const Duration(milliseconds: 200),
    );

    // Timeline may not be laid out on the first frame after controls appear.
    if (_showControls && measuredTop == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncSubtitlePadding();
      });
    }
  }

  double? _measureTimelineTop() {
    if (!_showControls) return null;

    final box =
        _timelineAnchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;

    return box.localToGlobal(Offset.zero).dy;
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
      title: _info.playerTitle,
      durationSeconds: _playerController.duration.inSeconds,
      positionSeconds: positionSeconds,
      playing: playing,
    );
  }

  void _toggleControls() {
    _update(() => _showControls = !_showControls);
    if (_showControls) {
      _refreshPositionUi(force: true);
      _scheduleSubtitlePaddingSync();
      _hideControlsWithDelay();
    }
  }

  void _handleVideoTap({bool togglePlayback = false}) {
    _keyboardFocusNode.requestFocus();
    // A finger on the picture counts as being there, exactly like a mouse move:
    // no countdown gets to act on a player someone is holding.
    _episodeNav?.onUserActivity();

    // Touch: one rule for all three zones, so the middle of the screen is not
    // a different player from its edges — and that rule is only ever about the
    // chrome. A tap shows it or puts it away; play and pause belong to the
    // button, which is a target the user aimed at. On a phone the film is
    // watched with the screen in reach of a hand that is also holding it, and
    // every stray touch stopping it — a thumb steadying the phone, a finger
    // reaching for the controls — is a pause nobody asked for.
    if (_handheld) {
      _toggleControls();
      return;
    }

    if (togglePlayback) {
      _togglePlayPause();
      _showControlsTransient();
      return;
    }
    _toggleControls();
  }

  /// A screen held in a hand: a phone or a tablet, and not a television.
  ///
  /// Three things turn on it — how a tap is read, whether a pinch can happen at
  /// all, and what "original" framing means — because all three are answers to
  /// the same fact: the screen is small, close, and touched. A remote drives
  /// the chrome with its own keys and never produces a tap.
  bool get _handheld => AppPlatform.isMobile && !TvMode.isTv;

  /// A window to move: see [_startWindowDrag].
  bool get _windowDragEnabled => AppPlatform.isDesktop;

  /// A double-click anywhere on the picture opens and closes full screen,
  /// instead of moving the film ten seconds.
  ///
  /// Only where there is a window to enlarge. On that kind of screen the
  /// double-click already means "take the whole display" in every other
  /// player, and the ±10 s jump has buttons a pointer can aim at. A thumb
  /// cannot aim, which is why a touchscreen keeps the double-tap that seeks:
  /// there the side zones *are* the buttons.
  bool get _doubleTapTogglesFullscreen => AppPlatform.isDesktop;

  /// Reads the brightness the screen is already on, so the bar opens where the
  /// user left it instead of jumping on first touch.
  Future<void> _loadScreenBrightness() async {
    final value = await ScreenBrightnessControl.current();
    if (value == null || !mounted || _isDisposing) return;
    _update(() => _screenBrightness = value);
  }

  void _setScreenBrightness(double value) {
    _update(() => _screenBrightness = value.clamp(0.0, 1.0));
    unawaited(ScreenBrightnessControl.set(value));
  }

  void _hideControlsWithDelay() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (_isDisposing) return;
      if (!mounted) return;
      if (!chromeMayAutoHide(
        isPlaying: _playerController.isPlaying,
        isDraggingSlider: _playerController.isDraggingSlider,
        menuOpen: _popups.isOpen,
      )) {
        return;
      }
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
        _update(() => _showControls = false);
      }
    });
  }

  /// Le chrome reste affiché tant qu'un doigt le tient (barre de lecture,
  /// luminosité), puis son compte à rebours repart au relâché.
  void _holdChromeWhile(bool holding) {
    if (holding) {
      _controlsTimer?.cancel();
      _safeSetState(() => _showControls = true);
    } else {
      _hideControlsWithDelay();
    }
  }

  /// Mouse moved over the video.
  ///
  /// Hover fires on every pointer sample — 60 to 120 times a second — and
  /// [_showControlsTransient] rebuilds the whole player tree, refreshes the
  /// timeline and re-measures the subtitle padding. Paying that per sample made
  /// the chrome stutter under the very gesture meant to summon it. When the
  /// chrome is already up there is nothing to show, so re-arming the countdown
  /// is the entire job.
  ///
  /// Et ce travail-là est lui-même espacé. Une souris de jeu rapporte jusqu'à
  /// mille positions par seconde : réarmer à chaque échantillon détruisait et
  /// reconstruisait mille `Timer` par seconde de mouvement, au-dessus d'une
  /// image 4K. Le compte à rebours dure quatre secondes — le décaler de deux
  /// dixièmes ne se voit pas, et c'est tout ce que coûte ce filtre.
  void _handlePointerHover() {
    _episodeNav?.onUserActivity();
    if (_showControls) {
      final now = DateTime.now();
      final last = _lastHoverRearm;
      if (last != null &&
          now.difference(last) < _PlayerScreenState._hoverRearmInterval) {
        return;
      }
      _lastHoverRearm = now;
      _hideControlsWithDelay();
      return;
    }
    _lastHoverRearm = DateTime.now();
    _showControlsTransient();
  }

  /// Whether one of the end-of-episode pages — the season request or the
  /// episode this season still awaits — currently owns the screen.
  bool get _endCardVisible => _episodeNav?.showEndCard ?? false;

  /// How much of the screen the video keeps. It gives way to an end card
  /// without ever being hidden: the credits stay visible and playing.
  double get _videoScale => _endCardVisible ? 0.34 : 1.0;

  void _showControlsTransient() {
    // Everything that raises the chrome does so because someone asked for it —
    // a seek, the volume, the remote entering the control bar. A countdown
    // started for an empty room has no business surviving that.
    _episodeNav?.onUserActivity();
    // The end card owns the screen: waking the HUD on every mouse move would
    // stack a progress bar and a play button over it.
    if (_endCardVisible || _stillWatchingAsked) return;
    _update(() => _showControls = true);
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
  bool get _controlsVisible =>
      _showControls &&
      !_endCardVisible &&
      !_screenLocked &&
      !_stillWatchingAsked;

  void _lockScreen() {
    _controlsTimer?.cancel();
    _popups.dismissTop();
    _update(() {
      _screenLocked = true;
      _showControls = false;
    });
  }

  void _unlockScreen() {
    if (!mounted || _isDisposing) return;
    _update(() => _screenLocked = false);
    // Celui qui vient de déverrouiller veut les commandes.
    _showControlsTransient();
  }

  /// Hide the cursor while controls are hidden during playback.
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

  Future<void> _openEpisodesPanel() async {
    if (!_info.isEpisode || _apiClient == null) return;
    _update(() => _showControls = true);
    _controlsTimer?.cancel();
    await _episodesPanel.open(showTitle: _info.showTitle);
  }

  void _closeEpisodesPanel() {
    if (!_episodesPanel.close()) return;
    _hideControlsWithDelay();
  }

  void _updateVideoFit(BoxFit fit) {
    // La surface est reconstruite avec le nouveau cadrage ; chaque moteur
    // l'applique à sa façon — Flutter met une texture à l'échelle, la vue
    // native se redimensionne elle-même.
    _update(() => _videoFit = fit);
  }

  /// Pinch-to-zoom, the gesture people expect on a phone: spreading two
  /// fingers fills the screen ([BoxFit.cover]), pinching them back gives the
  /// original framing ([BoxFit.contain]).
  void _applyPinchFit(BoxFit next) {
    if (next != _videoFit) _updateVideoFit(next);
    // Shown even when the fit does not change, so pinching a picture that
    // already fills the screen answers instead of doing nothing at all.
    _hints.showZoom(next);
  }

  /// A double-tap on one of the side zones: move the film, and say so.
  ///
  /// Separate from [_seekRelative] because the two have different audiences.
  /// The ±10 buttons and the media keys are already visible causes with a
  /// visible chrome to read the result off; a double-tap has neither, and is
  /// the only seek that can arrive several times in a second.
  void _handleDoubleTapSeek(int seconds) {
    _lastSideSeekAt = DateTime.now();
    _seekRelative(seconds);
    _hints.showSeek(seconds);
  }

  /// A double-click on the picture, on a desktop: full screen on, full screen
  /// off — see [_doubleTapTogglesFullscreen].
  ///
  /// The focus request is the same one every tap path makes: the keyboard
  /// shortcuts are on this screen's focus node, and a click that leaves it
  /// behind would take space and arrows with it.
  void _handleDoubleTapFullscreen() {
    _keyboardFocusNode.requestFocus();
    unawaited(_toggleFullscreen());
  }

  /// A single tap on a side zone: the same as a tap in the middle, so play and
  /// pause do not depend on aiming for the centre of the picture.
  ///
  /// Except in a seek burst. The double-tap recognizer pairs taps two by two,
  /// so the third tap of a quick run arrives here alone — and pausing the film
  /// in the middle of a rewind is not what that tap meant. While the last seek
  /// is still recent, a lone tap keeps seeking the same way instead.
  void _handleSideZoneTap(int seconds) {
    final last = _lastSideSeekAt;
    if (last != null &&
        DateTime.now().difference(last) <
            _PlayerScreenState._sideSeekBurstWindow) {
      _handleDoubleTapSeek(seconds);
      return;
    }
    _handleVideoTap(togglePlayback: true);
  }

  Future<void> _toggleFullscreen() async {
    final isFullScreen = await WindowControls.isFullScreen();
    await WindowControls.setFullScreen(!isFullScreen);
  }

  /// The player hides the caption bar, which was the only handle the window
  /// had: without this, a film started on one screen could not be carried to
  /// another. Dragging the picture moves the window instead — a click that
  /// does not move stays a tap, since the pan only claims a moving pointer.
  ///
  /// Not in full screen, where the window covers a display and moving it
  /// would only tear it off the edges.
  Future<void> _startWindowDrag() async {
    if (await WindowControls.isFullScreen()) return;
    await WindowControls.startDragging();
  }

  Future<void> _exitFullscreenIfActive() async {
    if (await WindowControls.isFullScreen()) {
      await WindowControls.setFullScreen(false);
    }
  }

  /// Chrome Onyx settings menu, anchored to the button that opened it.
  void _showOnyxSettingsMenu({
    OnyxMenuSection section = OnyxMenuSection.root,
    required GlobalKey anchorKey,
  }) {
    final screenSize = MediaQuery.sizeOf(context);
    final placement = placeSettingsPopup(anchorKey, screenSize);
    _popups.insert(
      context,
      (dismiss) => PlayerSettingsPopup(
        placement: placement,
        screenSize: screenSize,
        onDismiss: dismiss,
        child: OnyxSettingsMenu(
          session: _playerController.session,
          playerController: _playerController,
          episodeNav: _episodeNav,
          currentFit: _videoFit,
          onFitChanged: _updateVideoFit,
          playbackRate: _playbackRate,
          playbackRates: _PlayerScreenState._playbackRates,
          onRateChanged: _setPlaybackRate,
          onSeekToAbsolute: _seekTo,
          initialSection: section,
          onClose: dismiss,
        ),
      ),
    );
  }

  /// Le panneau s'ouvre partout où un serveur peut héberger une séance — pas
  /// pour le visiteur d'un lien de partage, qui n'a pas de compte pour en
  /// ouvrir une.
  VoidCallback? get _watchPartyAction =>
      _apiClient != null && !_apiClient!.isGuest ? _showWatchPartyPanel : null;

  void _showWatchPartyPanel() {
    _controlsTimer?.cancel();
    _popups.insert(
      context,
      (dismiss) => PlayerCenteredPopup(
        onDismiss: dismiss,
        child: WatchPartyPanel(
          party: _party.party,
          onStart: () async {
            await _party.start();
            dismiss();
            if (mounted) _showWatchPartyPanel();
          },
          onLeave: () {
            dismiss();
            _party.leave(notice: tr('Vous avez quitté la séance'));
          },
          onClose: () {
            dismiss();
            _hideControlsWithDelay();
          },
        ),
      ),
    );
  }

  Future<void> _setPlaybackRate(double rate) async {
    await _playerController.session.setRate(rate * _party.rateFactor);
    if (!mounted) return;
    _update(() => _playbackRate = rate);
    _showControlsTransient();
  }

  Future<void> _cyclePlaybackRate() async {
    const rates = _PlayerScreenState._playbackRates;
    final idx = rates.indexOf(_playbackRate);
    final next = rates[(idx < 0 ? 0 : idx + 1) % rates.length];
    await _playerController.session.setRate(next * _party.rateFactor);
    if (!mounted) return;
    _update(() => _playbackRate = next);
    _showControlsTransient();
  }

  /// Downloaded-ahead fraction for the Chrome Onyx scrubber.
  double get _bufferedFraction {
    final total = _playerController.duration.inSeconds;
    if (total <= 0) return 0;
    return (_playerController.session.bufferedAhead.inSeconds / total)
        .clamp(0.0, 1.0);
  }

  /// Chapter starts as fractions, for the Chrome Onyx scrubber ticks. Empty when the
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

  Widget _buildChrome(bool isTv) {
    final nav = _episodeNav;
    return OnyxControlsLayer(
      visible: _controlsVisible,
      timelineAnchorKey: _timelineAnchorKey,
      isPlaying: _playerController.isPlaying,
      position: _displayedPosition,
      duration: _playerController.duration,
      buffered: _bufferedFraction,
      onPlayPause: _togglePlayPause,
      onRewind: () => _seekRelative(-10),
      onForward: () => _seekRelative(10),
      // The scrubber under the remote chains its steps instead
      // of seeking on each one — see [_remoteSeekStep].
      onScrubStepBack: () => _remoteSeekStep(-1),
      onScrubStepForward: () => _remoteSeekStep(1),
      // Walking the chrome is using it: the countdown that
      // hides it starts over.
      onRemoteNavigate: _hideControlsWithDelay,
      onSeekFraction: _seekToFraction,
      // Hold the chrome open for the whole drag, then start
      // the hide countdown again on release.
      onScrubbingChanged: _holdChromeWhile,
      title: _info.showTitle,
      overline: _info.overline,
      logoUrl: _mediaLogoUrl,
      volume: _playerController.session.volume,
      onVolumeChanged: (v) => _playerController.session.setVolume(v),
      brightness: _screenBrightness,
      onBrightnessChanged: _setScreenBrightness,
      // Same deal as the scrubber: the chrome cannot fade out
      // from under a finger that is still on it.
      onBrightnessDraggingChanged: _holdChromeWhile,
      onBack: _leavePlayer,
      onToggleSubtitles: () => _showOnyxSettingsMenu(
        section: OnyxMenuSection.subtitles,
        anchorKey: _subtitlesButtonKey,
      ),
      onOpenAudio: () => _showOnyxSettingsMenu(
        section: OnyxMenuSection.audio,
        anchorKey: _subtitlesButtonKey,
      ),
      onCycleSpeed: _cyclePlaybackRate,
      onOpenSettings: () => _showOnyxSettingsMenu(
        anchorKey: _settingsButtonKey,
      ),
      onOpenWatchParty: _watchPartyAction,
      watchPartyActive: _party.party != null,
      onToggleFullscreen: _toggleFullscreen,
      playbackRate: _playbackRate,
      onLockScreen: _handheld ? _lockScreen : null,
      onSkipNext: nav?.nextEpisode != null ? _goToNextEpisode : null,
      onSkipPrevious: _episodesPanel.previousEpisode != null
          ? _goToPreviousEpisode
          : null,
      onOpenEpisodes: _info.isEpisode ? _openEpisodesPanel : null,
      onSkipIntro:
          (nav?.showSkipIntro ?? false) ? _skipIntroFromControl : null,
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
      // Only non-null once the first frame is on screen.
      previews: _playerController.timelinePreviews,
      remoteSeekPending: _remoteSeek.target != null,
      // The phone has volume keys; the desktop has nothing but
      // this.
      showVolume: !AppPlatform.isMobile,
      scale: _chromeScale,
    );
  }
}
