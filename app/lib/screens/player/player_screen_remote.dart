part of 'player_screen.dart';

/// Le clavier et la télécommande : à qui revient le focus, ce que fait chaque
/// touche, et le Retour qui défait les couches une à une.
extension _PlayerRemote on _PlayerScreenState {
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
    if (!_keyboardFocusNode.hasFocus && !_popups.isOpen && !_isLeaving) {
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
  void _enterControlBar([_RemoteEntry entry = _RemoteEntry.playPause]) {
    _remoteEntry = entry;
    _showControlsTransient();
  }

  /// One step of a remote seek: left or right, pressed or held.
  void _remoteSeekStep(int direction) {
    // A swipe on the Apple TV touchpad already moves the scrubber with the
    // finger ([_handleTouchpadMove]); the arrow the engine derives from that
    // same swipe would count it twice.
    if (!TvTouchpad.isSwiping) {
      _remoteSeek.step(
        direction,
        fromSeconds: _playerController.position.inSeconds,
        durationSeconds: _playerController.duration.inSeconds,
      );
    }
    _showControlsTransient();
  }

  /// Le doigt glisse sur le trackpad de l'Apple TV : là où gauche et droite
  /// feraient avancer le film (le film lui-même, ou la barre de lecture), la
  /// cible suit le doigt, d'autant plus loin qu'il va vite (ADR-0039).
  void _handleTouchpadMove(TouchpadMove move) {
    if (!_isInitialized || _isDisposing || !TvMode.isTv) return;
    // Un glissé vertical appelle les commandes, par les flèches du moteur.
    if (move.dx.abs() < move.dy.abs()) return;
    if (_popups.isOpen || _episodesPanel.isOpen || _endCardVisible) return;
    final seeks = !_remoteBrowsingControls || _progressFocusNode.hasPrimaryFocus;
    if (!seeks) return;
    _remoteEntry = _RemoteEntry.scrubber;
    _remoteSeek.scrub(
      move.dx,
      speed: move.speed,
      fromSeconds: _playerController.position.inSeconds,
      durationSeconds: _playerController.duration.inSeconds,
    );
    _showControlsTransient();
  }

  /// The position the chrome shows: a remote seek's target while one is
  /// pending, the player's own otherwise.
  Duration get _displayedPosition {
    final target = _remoteSeek.target;
    return target != null ? Duration(seconds: target) : _playerController.position;
  }

  /// The invariant that makes the remote legible: on a television, chrome on
  /// screen means something on it is outlined.
  ///
  /// The player used to keep the focus for itself while the HUD was up, which
  /// gave two indistinguishable states — same picture, same bar, but in one of
  /// them nothing was highlighted and the arrows scrubbed, and in the other a
  /// button was highlighted and the arrows walked. Which one you were in
  /// depended on whether the HUD had been woken by OK or by a seek. This
  /// collapses them into one: the HUD is up, something is outlined — the
  /// scrubber if the remote came in seeking, play/pause otherwise (see
  /// [_remoteEntry]).
  void _ensureRemoteInChrome() {
    if (!TvMode.isTv) return;
    if (_isDisposing || _isLeaving || !_showControls) return;
    // A popup, the episode browser or an end card owns the focus while it is
    // up, and taking it back would trap the remote behind them.
    if (_popups.isOpen || _episodesPanel.isOpen || _endCardVisible) return;

    // After the frame: a hidden chrome excludes its own controls from focus,
    // so until it is painted there is nothing for the focus to land on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposing || _isLeaving) return;
      if (!_showControls || _popups.isOpen || _episodesPanel.isOpen) return;
      // Already standing on a control — including one the user walked to.
      // Re-requesting would drag them back to the scrubber on every seek.
      if (_remoteBrowsingControls) return;
      final preferred = _remoteEntry == _RemoteEntry.scrubber
          ? [_progressFocusNode, _playPauseFocusNode]
          : [_playPauseFocusNode, _progressFocusNode];
      _remoteEntry = _RemoteEntry.playPause;
      for (final node in preferred) {
        if (node.context != null) {
          node.requestFocus();
          return;
        }
      }
      // Chromes with neither node fall back to whatever traversal reaches
      // first.
      _keyboardFocusNode.nextFocus();
    });
  }

  /// Takes the remote back off the control bar.
  void _leaveControlBar() {
    _keyboardFocusNode.requestFocus();
    _update(() => _showControls = false);
  }

  KeyEventResult _handlePlayerKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isInitialized || _isDisposing) return KeyEventResult.ignored;
    // La question a ses deux boutons, et rien d'autre ne répond : une touche
    // qui relancerait la lecture y répondrait à la place de quelqu'un.
    if (_stillWatchingAsked) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // Whatever the key turns out to do — even nothing at all — pressing one
    // means someone is watching, so the intro and the next episode stop
    // counting down.
    _episodeNav?.onUserActivity();

    final mediaResult = _mediaKeys.handleKeyboardEvent(event);
    if (mediaResult != null) return mediaResult;

    final browsingControls = _remoteBrowsingControls;

    // Any key pressed while the remote is on the control bar means the user is
    // there, so the hide countdown starts over — the same thing a mouse move
    // does for a pointer. Without it the bar would fade out mid-navigation.
    if (browsingControls) _hideControlsWithDelay();

    final action = routePlayerKey(
      event,
      isTv: TvMode.isTv,
      browsingControls: browsingControls,
      chromeVisible: _showControls,
      skipIntroShown: _episodeNav?.showSkipIntro ?? false,
    );
    switch (action) {
      case PlayerKeyIgnored():
        return KeyEventResult.ignored;
      case PlayerKeyConsumed():
        break;
      case PlayerKeySkipIntro():
        unawaited(_skipIntroFromControl());
      case PlayerKeyEnterControlBar():
        _enterControlBar(_RemoteEntry.playPause);
      case PlayerKeyTogglePlayback():
        _togglePlayPause();
      case PlayerKeyShortcut(:final match):
        _runShortcut(match);
      case PlayerKeyRemoteSeek(:final direction):
        _remoteEntry = _RemoteEntry.scrubber;
        _remoteSeekStep(direction);
      case PlayerKeySeek(:final seconds):
        _seekRelative(seconds);
      case PlayerKeyVolume(:final delta):
        _adjustVolume(delta);
      case PlayerKeyBack():
        // Innermost first: a menu opened from the chrome, then the episode
        // panel, then the control bar, and only then the player itself.
        if (_popups.dismissTop()) break;
        if (_episodesPanel.isOpen) {
          _closeEpisodesPanel();
          break;
        }
        if (browsingControls) {
          _leaveControlBar();
          break;
        }
        unawaited(_exitFullscreenIfActive());
    }
    return KeyEventResult.handled;
  }

  /// Le Retour du système (la télécommande, le geste du téléphone) : il défait
  /// la même pile que la touche, du plus intérieur au lecteur lui-même.
  Future<void> _handleBack() async {
    // Devant la question, Retour est une réponse : « non ».
    if (_stillWatchingAsked) {
      await _leavePlayer();
      return;
    }
    // Écran verrouillé, le Retour du système ne quitte pas le film : il
    // montre le cadenas, comme un appui sur l'image.
    if (_screenLocked) {
      _screenLockKey.currentState?.reveal();
      return;
    }
    // The remote's Back arrives here, not as a key event — and it has to
    // unwind the same stack the key path does, innermost first, or it
    // walks out of the film with a menu still open on top of it.
    if (_popups.dismissTop()) return;
    if (_episodesPanel.isOpen) {
      _closeEpisodesPanel();
      return;
    }
    // On the control bar Back means "put that away", not "leave".
    if (_remoteBrowsingControls) {
      _leaveControlBar();
      return;
    }
    await _leavePlayer();
  }

  void _runShortcut(PlayerShortcutMatch match) {
    switch (match.shortcut) {
      case PlayerShortcut.playPause:
        _togglePlayPause();
      case PlayerShortcut.seekBack:
        _seekRelative(-10);
      case PlayerShortcut.seekForward:
        _seekRelative(10);
      case PlayerShortcut.toggleFullscreen:
        if (AppPlatform.isDesktop || AppPlatform.isWeb) {
          unawaited(_toggleFullscreen());
        }
      case PlayerShortcut.toggleMute:
        togglePlayerMute(_playerController.session);
        _showControlsTransient();
        _safeSetState(() {});
      case PlayerShortcut.nextEpisode:
        if (_episodeNav?.nextEpisode != null) _goToNextEpisode();
      case PlayerShortcut.seekToFraction:
        _seekToFraction(match.fraction);
      case PlayerShortcut.showHelp:
        unawaited(showPlayerShortcutsHelp(context));
    }
  }

  void _adjustVolume(double delta) {
    final session = _playerController.session;
    final next = (session.volume + delta).clamp(0.0, 100.0);
    session.setVolume(next);
    _showControlsTransient();
    _safeSetState(() {});
  }

  void _handleMediaFastForward() {
    if (_episodeNav?.nextEpisode != null) {
      _goToNextEpisode();
    } else {
      _seekRelative(10);
    }
  }
}
