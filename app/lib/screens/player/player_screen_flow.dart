part of 'player_screen.dart';

/// Le déroulé d'une lecture une fois lancée : ce qui la déplace, ce qui
/// l'enchaîne, et ce qu'elle laisse en partant.
extension _PlayerFlow on _PlayerScreenState {
  void _onPositionChanged() {
    if (_isDisposing || !mounted) return;
    _syncPictureInPicture();
    _episodeNav?.checkPosition(
      _playerController.position.inSeconds,
      mediaDurationSeconds: _playerController.duration.inSeconds,
    );
    unawaited(_syncMediaSession());
    _refreshPositionUi();
  }

  void _onPlaybackCompleted() {
    if (_isDisposing || !mounted) return;
    _safeSetState(() {});
    // La minuterie de veille passe avant tout le reste : une carte de fin
    // laissée à l'écran tiendrait le lecteur ouvert toute la nuit.
    if (SleepTimer.instance.takeLastEpisodeEnd()) {
      unawaited(_leavePlayer());
      return;
    }
    // An end card wins over auto-advance: leaving would answer its question by
    // walking away from it, and both cards carry their own "next episode".
    // Staying on the last frame is what keeps them there to be acted on.
    //
    // The gap card goes first: when the library holds a later season, crossing
    // a hole in this one has to stay a deliberate act, never an auto-advance.
    if (_episodeNav?.revealUpcomingEpisodeCard() ?? false) return;
    if (_episodeNav?.nextEpisode != null && !_endCardVisible) {
      _autoAdvanceToNextEpisode();
      return;
    }
    if (_episodeNav?.revealNextSeasonCard() ?? false) return;
    unawaited(_leavePlayer());
  }

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
    _seekTo(target);
    _showControlsTransient();
  }

  /// Seek from a progress-bar fraction.
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
    _seekTo((fraction * totalSeconds).round());
    _showControlsTransient();
  }

  /// Toute recherche voulue par la personne devant l'écran passe ici, pour que
  /// la séance, s'il y en a une, suive. Les recalages venus de la séance, eux,
  /// vont droit au contrôleur (voir [PlayerWatchParty]).
  Future<void> _seekTo(int absoluteSeconds) async {
    final target = absoluteSeconds < 0 ? 0 : absoluteSeconds;
    // Annoncé avant d'attendre : une reconstruction de session HLS peut
    // prendre plusieurs secondes, les autres n'ont pas à les attendre.
    final party = _party.party;
    if (party != null) {
      unawaited(party.sendSeek(Duration(seconds: target),
          playing: _playerController.isPlaying));
    }
    await _playerController.seekToAbsoluteSeconds(target);
  }

  /// La lecture s'arrête parce qu'on l'a décidé (minuterie, autre appareil,
  /// question sans réponse) : rien ne doit la relancer derrière.
  void _pauseByChoice() {
    _wantsPlayback = false;
    if (_playerController.isPlaying) _playerController.togglePlayPause();
  }

  void _togglePlayPause() {
    // En pause parce que la lecture est passée ailleurs : relancer ici, c'est
    // la reprendre, pas lire en double.
    if (_handoff.handedOffTo != null) {
      unawaited(_handoff.resumeHere());
      return;
    }
    // Une touche de casque ou la notification du système arrivent ici sans
    // passer par le clavier ni par l'écran. Devant la question, « lecture »
    // est la réponse « oui » — pas une reprise sous le panneau.
    if (_stillWatchingAsked) {
      _confirmStillWatching();
      return;
    }
    StillWatching.instance.noteActivity();
    _wantsPlayback = !_playerController.isPlaying;
    _playerController.togglePlayPause();
    final party = _party.party;
    if (party != null) {
      unawaited(party.sendPlaying(
          _playerController.isPlaying, _playerController.position));
    }
    _hideControlsWithDelay();
  }

  /// La minuterie de veille est arrivée à son terme : la lecture s'arrête ici.
  ///
  /// Un lecteur qui s'en va ou qui n'a pas encore démarré laisse l'échéance en
  /// place : c'est l'épisode suivant qui la prendra. Voir [SleepTimer].
  void _applySleepTimer() {
    if (!mounted || _isLeaving || _isDisposing || !_isInitialized) return;
    // Le compte en épisodes change ce que montre la pastille du générique.
    _update(() {});
    if (!SleepTimer.instance.takeDue()) return;
    _pauseByChoice();
    _party.showNotice(tr('Minuterie de veille : lecture en pause'));
    _showControlsTransient();
  }

  /// The intro skipping itself: the countdown ran out with nobody touching
  /// anything. The controller has already put the button away, so all that is
  /// left is the seek — done quietly, without waking the chrome, since there is
  /// by definition nobody in front of it.
  Future<void> _autoSkipIntro() async {
    final nav = _episodeNav;
    if (nav == null || _isDisposing || !mounted) return;
    await _seekTo(nav.introSkipTarget);
  }

  Future<void> _skipIntroFromControl() async {
    final nav = _episodeNav;
    if (nav == null || !nav.showSkipIntro) return;
    final end = nav.introSkipTarget;
    await _seekTo(end);
    nav.skipIntro();
    _showControlsTransient();
  }

  /// L'épisode suivant, lancé par le lecteur et non par quelqu'un : la fin du
  /// compte à rebours du générique, ou la fin du fichier.
  ///
  /// C'est le seul endroit où [StillWatching] peut retenir l'enchaînement. Un
  /// « épisode suivant » demandé à la main ne passe pas par ici.
  void _autoAdvanceToNextEpisode() {
    if (_stillWatchingAsked) return;
    final sleep = SleepTimer.instance;
    // Le dernier épisode de la minuterie va au bout de son générique : rien ne
    // l'attend derrière, il n'y a pas de quoi l'abréger. Sa fin de fichier est
    // prise par [_onPlaybackCompleted].
    if (sleep.stopsAfterThisEpisode) return;
    // Compté avant la question : y répondre « oui » enchaîne sans repasser ici.
    sleep.episodeFinished();
    // En séance partagée, d'autres regardent : leur présence vaut la nôtre.
    if (_party.party == null && !StillWatching.instance.allowAutoAdvance()) {
      _askStillWatching();
      return;
    }
    _goToNextEpisode();
  }

  void _askStillWatching() {
    if (!mounted || _isLeaving || _isDisposing) return;
    _popups.dismissTop();
    _closeEpisodesPanel();
    _controlsTimer?.cancel();
    _pauseByChoice();
    _update(() {
      _stillWatchingAsked = true;
      _showControls = false;
      // Un écran verrouillé avalerait le doigt qui vient répondre.
      _screenLocked = false;
    });
  }

  void _confirmStillWatching() {
    StillWatching.instance.noteActivity();
    _update(() => _stillWatchingAsked = false);
    _keyboardFocusNode.requestFocus();
    if (_episodeNav?.nextEpisode != null) {
      _goToNextEpisode();
      return;
    }
    _togglePlayPause();
  }

  void _goToNextEpisode() {
    final next = _episodeNav?.nextEpisode;
    if (next == null) return;
    _navigateToEpisode(next);
  }

  void _goToPreviousEpisode() {
    final previous = _episodesPanel.previousEpisode;
    if (previous == null) return;
    _navigateToEpisode(previous);
  }

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

  Future<void> _requestNextSeason() async {
    final season = _episodeNav?.nextSeason;
    if (season == null || _requestingNextSeason || !season.canRequest) return;
    if (season.showTmdbId <= 0) return;

    _update(() => _requestingNextSeason = true);
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
          SnackBar(content: Text(tr('Impossible d’envoyer la demande.'))),
        );
      }
    } finally {
      if (mounted) _update(() => _requestingNextSeason = false);
    }
  }

  void _navigateToEpisode(
    HomeMediaItem next, {
    bool fromParty = false,
    int? resumeAtSeconds,
    bool startPaused = false,
  }) {
    if (next.media.id == _info.media.id) {
      _closeEpisodesPanel();
      return;
    }

    _closeEpisodesPanel();
    _isEpisodeTransition = true;
    _isLeaving = true;
    // La séance passe à l'épisode avec ce lecteur.
    if (_party.carryTo(next.media.id, fromParty: fromParty)) {
      resumeAtSeconds ??= 0;
    }
    final inheritedPreferences = _playerController.exportPreferences();
    final videoFit = _videoFit;

    // Cancel all streams BEFORE navigation
    _playerController.cancelStreams();
    // Relevé avant de jeter la navigation : c'est elle qui sait où est le
    // générique, et la progression part juste après.
    _leftDuringCredits = _episodeNav?.showNextEpisodeOutro ?? false;
    if (_episodeNav != null && _episodeNavListener != null) {
      _episodeNav!.removeListener(_episodeNavListener!);
      _episodeNav!.dispose();
      _episodeNav = null;
      _episodeNavListener = null;
    }

    unawaited(_syncProgressOnExit(popAfter: false));

    // L'ancien moteur s'arrête avant que le suivant ne s'ouvre, pas à la
    // destruction de cet écran. Sur iOS, mpv désactive la session audio de
    // l'app en libérant sa sortie : un épisode téléchargé, qui démarre presque
    // aussitôt, jouait déjà quand cet arrêt tombait, et se figeait en pause.
    // La position envoyée au serveur est celle du contrôleur, lue ci-dessus.
    final stopped = _playerController.session
        .stop()
        .timeout(const Duration(seconds: 1))
        .catchError((Object _) {
      // Un moteur qui ne s'arrête pas à temps ne retient pas l'épisode
      // suivant : il sera libéré à la destruction de cet écran.
    });

    // Awaiting the stop also lets pending stream events flush safely.
    unawaited(stopped.then((_) {
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
            seasonNumber: _info.seasonNumberFor(next),
            resumeAtSeconds: resumeAtSeconds,
            startPaused: startPaused,
          ),
        ),
      );
    }));
  }

  Future<void> _syncProgressOnExit({required bool popAfter}) async {
    if (_progressFlushed) {
      if (popAfter && mounted) Navigator.of(context).pop();
      return;
    }
    _progressFlushed = true;
    _controlsTimer?.cancel();

    final actualMedia = _info.media;
    final sourceItem = _info.item;

    final posSeconds = _playerController.position.inSeconds;
    var durSeconds = _playerController.duration.inSeconds;
    if (durSeconds <= 0) durSeconds = _info.knownDurationSeconds;

    final isFinished = countsAsWatched(
      positionSeconds: posSeconds,
      durationSeconds: durSeconds,
      leftDuringCredits:
          _leftDuringCredits || (_episodeNav?.showNextEpisodeOutro ?? false),
    );

    HomeProvider? homeProvider;
    LibraryProvider? libraryProvider;
    if (mounted) {
      homeProvider = Provider.of<HomeProvider>(context, listen: false);
      libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
      // Une progression cédée à un autre appareil n'a rien à montrer ici :
      // la rangée attend ce que le serveur dira de lui.
      if (posSeconds > 0 && _playerController.reporter.ownsProgress) {
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
    // Les pastilles « vu / en cours » de la bibliothèque sont calculées côté
    // serveur : sans ce rafraîchissement, l'épisode qu'on vient de finir n'y
    // compterait qu'au prochain démarrage.
    unawaited(libraryProvider?.refreshCatalogSilently() ?? Future.value());

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
    // Quitter le lecteur, c'est quitter la séance : les autres continuent.
    _party.leaveWithPlayer();
    // Dans un navigateur, le plein écran appartient au film : hors du lecteur,
    // plus aucun bouton ne permettrait d'en sortir.
    if (AppPlatform.isWeb) unawaited(_exitFullscreenIfActive());
    return _syncProgressOnExit(popAfter: true);
  }
}
