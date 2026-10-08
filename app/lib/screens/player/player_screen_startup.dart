part of 'player_screen.dart';

/// Le démarrage d'une lecture : le serveur épinglé, le point de reprise,
/// l'ouverture du flux — et ce qui se passe quand l'image ne vient pas
/// (délai dépassé, relance, relais par un autre serveur).
extension _PlayerStartup on _PlayerScreenState {
  /// How long the picture may take before the screen admits something is wrong.
  ///
  /// Long enough not to fire on a genuinely slow open — a big remux over a
  /// weak link, a server that has to spin a disk up — and short enough that
  /// nobody sits through it twice wondering whether to press something.
  static const Duration _startupDeadline = Duration(seconds: 25);

  Future<void> _init() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final sharedApi = authProvider.apiClient;
    _sourceAccountId = sharedApi.accountId;
    final apiClient = _sourceAccountId == null ? sharedApi : await sharedApi.pinToAccount(_sourceAccountId!);
    if (!mounted || _isLeaving) return;
    _apiClient = apiClient;
    _party.sync();
    if (_sourceAccountId != null) {
      unawaited(sharedApi.mediaFailover.refreshIdentities(_sourceAccountId!));
      _relayTimer = Timer.periodic(const Duration(seconds: 10), (_) => _tryRelay());
    }
    _seedOfflineDetails();

    final actualMedia = _info.media;
    final item = _info.item;

    _resumePosition = widget.resumeAtSeconds ??
        (item != null && !item.isFinished ? item.currentPositionSeconds : 0);
    final resumePositionFuture = _loadResumePosition(apiClient, actualMedia).then((position) {
      _resumePosition = position;
      return position;
    });

    await _playerController.init(
      media: actualMedia,
      apiClient: apiClient,
      knownDurationSeconds: _info.knownDurationSeconds,
      inheritedPreferences: widget.inheritedPreferences,
      // Handed over rather than awaited here: the controller needs the resume
      // point at the exact moment it opens the stream, so mpv can start at that
      // second instead of starting at 0 and seeking afterwards.
      resumePositionFuture: resumePositionFuture,
      // What the home row already knows: lets the stream open without waiting
      // on the server, which only has to confirm it.
      provisionalResumeSeconds: widget.autoAdvance ? 0 : _resumePosition,
      onCompleted: _onPlaybackCompleted,
      onPositionChanged: _onPositionChanged,
      onPlayingChanged: () {
        _safeSetState(() {});
        unawaited(_syncMediaSession(force: true));
      },
      onDurationChanged: () {
        if (_isDisposing || !mounted) return;
        _update(() {});
      },
      onQualitySwitchingChanged: () {
        _safeSetState(() {});
      },
      onBufferingChanged: () {
        _relayTrigger.noteBuffering(_playerController.isBuffering);
        _safeSetState(() {});
      },
      onFirstFrame: () {
        // The picture is here; nothing left for the deadline to catch.
        _startupWatchdog?.cancel();
        // Le lecteur sait enfin où il en est : c'est le moment de le caler sur
        // la séance, au lieu d'attendre la prochaine vérification.
        _party.party?.resync();
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
      onFailure: () {
        // Le moteur a renoncé. Il n'y a plus rien à attendre du compte à
        // rebours : l'écran d'échec sait maintenant quoi dire, et le dire tout
        // de suite vaut mieux que le dire dans vingt secondes.
        _startupWatchdog?.cancel();
        _safeSetState(() => _startupStalled = true);
      },
    );

    if (!mounted || _isLeaving) return;
    unawaited(_loadMediaLogo());

    if (actualMedia.type == MediaType.episode) {
      // Extract timestamps from the media if available (from season episodes list)
      EpisodeTimestamps? initialTimestamps;
      if (item != null) {
        initialTimestamps = EpisodeTimestamps(
          introStart: item.introStart,
          introEnd: item.introEnd,
          outroStart: item.outroStart,
          outroEnd: item.outroEnd,
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
        onAutoPlay: _autoAdvanceToNextEpisode,
        onAutoSkipIntro: _autoSkipIntro,
      );
      _episodeNav!.addListener(_episodeNavListener!);
      unawaited(_episodeNav!.load());
      unawaited(_episodesPanel.loadPreviousEpisode());
    }

    if (mounted) _update(() {});
    final resumeAt = await resumePositionFuture;
    if (!mounted || _isLeaving) return;
    await _startPlayback(resumeAtSeconds: resumeAt);
  }

  Future<void> _loadMediaLogo() async {
    final api = _apiClient;
    final detailsId = _info.logoDetailsId;
    if (api == null || detailsId == null) return;

    // Already resolved this session (detail page, or a previous playback):
    // set it synchronously so the chrome opens on the logo, not on the title.
    // The URL is normalised to the same size the detail header asked for, so
    // the bytes are in the image cache too and it draws on the first frame.
    final cached = MediaDetailsCache.peek(detailsId);
    if (cached != null) {
      _update(() => _mediaLogoUrl = logoImageUrl(cached.logoUrl));
      return;
    }

    final url = await MediaDetailsCache.resolveLogo(api, detailsId);
    if (!mounted) return;
    _update(() => _mediaLogoUrl = logoImageUrl(url));
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
    final details = downloads.offlineDetails(_info.media.id);
    if (details == null) return;
    // Sous l'identifiant qui a servi à la demander : le lecteur cherche la
    // fiche par l'identifiant de la série, pas par celui de l'épisode.
    final infoId = downloads.entryFor(_info.media.id)?.infoId;
    MediaDetailsCache.remember(infoId ?? details.id, details);
  }

  Future<int> _loadResumePosition(
    ApiClient apiClient,
    Media actualMedia,
  ) async {
    // An episode reached by auto-advance always starts at zero, and the answer
    // below is discarded — so asking at all would just put an HTTP round-trip
    // in front of the picture, now that the open waits on this.
    if (widget.resumeAtSeconds != null) return widget.resumeAtSeconds!;
    if (widget.autoAdvance) return 0;

    int savedPositionSeconds = 0;
    final item = _info.item;
    if (item != null && !item.isFinished) {
      savedPositionSeconds = item.currentPositionSeconds;
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
        } else {
          savedPositionSeconds = fromApi;
        }
      } catch (e) {
        debugPrint("Player: Failed to query progress: ${redactPlaybackDiagnostic(e)}");
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
    if (!mounted || _isLeaving) return;

    await _playerController.startPlayback(
      mediaId: _info.media.id,
      apiClient: _apiClient!,
      resumeAtSeconds: resumeAtSeconds,
    );
    if (!mounted || _isLeaving) return;
    if (widget.startPaused) await _playerController.session.pause();
    _update(() => _isInitialized = true);
    // L'échéance a pu tomber pendant le passage à cet épisode.
    _applySleepTimer();
    _handoff.start();
    _armStartupWatchdog();
    _scheduleSubtitlePaddingSync();
    unawaited(_mediaKeys.attach(
      title: _info.playerTitle,
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
      _update(() => _startupStalled = true);
    });
  }

  Future<void> _tryRelay() async {
    final source = _sourceAccountId;
    if (!mounted || _isLeaving || _isDisposing || _findingRelay || source == null) return;
    // Une séance vit sur un serveur : basculer sur un autre y couperait
    // l'appareil des autres participants.
    if (_party.party != null) return;
    final media = _info.media;
    if (DownloadManager.instance.localVideoPath(media.id) != null) return;
    final auth = context.read<AuthProvider>();
    if (auth.activeServer?.id != source) return;
    if (!_relayTrigger.inTrouble(hasFirstFrame: _playerController.hasFirstFrame)) return;
    _findingRelay = true;
    try {
      final relay = await auth.apiClient.mediaFailover.findReplacement(
        sourceAccountId: source, media: media,
        excluded: widget.relayAttempts.entries
            .where((attempt) => DateTime.now().difference(attempt.value) < const Duration(seconds: 30))
            .map((attempt) => attempt.key).toSet(),
      );
      if (relay == null || !mounted || _isLeaving || auth.activeServer?.id != source) return;
      var position = _playerController.hasFirstFrame
          ? _playerController.position.inSeconds : _resumePosition;
      if (!_playerController.hasFirstFrame && position == 0 &&
          !widget.autoAdvance && widget.resumeAtSeconds == null) {
        position = relay.resumeAtSeconds;
      }
      final preferences = _playerController.exportPreferences();
      // The old player remains pinned while the destination authenticates.
      // Retire it only once the destination is ready.
      _isLeaving = true;
      final switched = await auth.switchServer(relay.account.id, synchronize: false);
      if (!mounted) return;
      if (!switched) {
        await auth.switchServer(source, synchronize: false);
        _isLeaving = false;
        _safeSetState(() => _startupStalled = true);
        return;
      }
      final targetApi = await auth.apiClient.pinToAccount(relay.account.id);
      if (!mounted) return;
      if (_playerController.hasFirstFrame) position = _playerController.position.inSeconds;
      final paused = !_wantsPlayback;
      _playerController.cancelStreams();
      _progressFlushed = true;
      _relayTimer?.cancel();
      unawaited(targetApi.sendProgress(mediaId: relay.media.id,
          currentPositionSeconds: position, duration: relay.media.duration,
          isFinished: false, clientUpdatedAt: DateTime.now().toUtc())
          .catchError((Object _) => false));
      if (!mounted) return;
      _isEpisodeTransition = true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Lecture reprise sur {0}.', [relay.account.displayName])),
      ));
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
        builder: (_) => PlayerScreen(media: relay.media,
          inheritedPreferences: preferences, initialVideoFit: _videoFit,
          seasonNumber: widget.seasonNumber, resumeAtSeconds: position,
          startPaused: paused, relayAttempts: {...widget.relayAttempts, source: DateTime.now()}),
      ));
    } on Object catch (error) {
      debugPrint('Player relay unavailable: ${redactPlaybackDiagnostic(error)}');
      if (mounted && !_progressFlushed) {
        try {
          await auth.switchServer(source, synchronize: false);
        } on Object catch (restoreError) {
          debugPrint('Player source restoration failed: $restoreError');
        }
        _isLeaving = false;
      }
    } finally { _findingRelay = false; }
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
    _party.handOver = true;
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
}
