part of 'use_player_controller.dart';

/// L'ouverture d'un média : le droit de lecture, la source (fichier local,
/// Direct Play ou session HLS), les abonnements au moteur, puis le départ au
/// point de reprise.
extension PlayerControllerStartup on PlayerController {
  Future<void> init({
    required Media media,
    required ApiClient apiClient,
    required VoidCallback onCompleted,
    required VoidCallback onPositionChanged,
    required VoidCallback onDurationChanged,
    VoidCallback? onPlayingChanged,
    VoidCallback? onQualitySwitchingChanged,
    VoidCallback? onBufferingChanged,
    VoidCallback? onFirstFrame,
    VoidCallback? onTracksChanged,
    VoidCallback? onFailure,
    PlayerPlaybackPreferences? inheritedPreferences,
    int knownDurationSeconds = 0,
    Future<int>? resumePositionFuture,
    int provisionalResumeSeconds = 0,
  }) async {
    _mark('init');
    _reporter.markLogStart();
    // Un moteur repris au vestiaire peut encore décharger le film précédent.
    // Ouvrir par-dessus est ce qui laissait une lecture derrière un indicateur
    // qui ne s'arrêtait jamais.
    await session.prepare();
    if (_disposed) return;
    _mark('engine');
    _resumePositionFuture = resumePositionFuture;
    // Must run before media_kit injects hls.js: the bridge intercepts the
    // assignment of `window.Hls` so it can reclaim abandoned instances later.
    WebPlayback.install();

    try {
      await session.applyDirectPlayTuning(PlaybackProfiles.current);
    } catch (e) {
      debugPrint(
          "Player: failed to apply native MPV properties: ${redactPlaybackDiagnostic(e)}");
    }
    _mark('tuned');

    if (_disposed) return;
    _positionSubscription = session.positions.listen((pos) {
      if (_disposed) return;
      // A session swap retires one stream and starts another. Until the new one
      // is fully wired, mpv can still emit positions belonging to the old
      // stream, and combining those with the new start offset yields an
      // absolute position that belongs to neither — large enough, on a big
      // seek, to exceed the media duration and blow up the progress bar.
      if (_hlsSwapInFlight) return;
      position = (currentQuality != null && _hlsStartOffset > 0)
          ? pos + Duration(seconds: _hlsStartOffset)
          : pos;
      // The clock advancing is the first moment the user is genuinely watching.
      if (isPlaying) {
        _notePlaying();
        _clockRunning = true;
        _maybeMarkFirstFrame();
      }
      onPositionChanged();
    });

    _playingSubscription = session.playingChanges.listen((playing) {
      if (_disposed) return;
      _setPlaying(playing);
    });

    _bufferingSubscription = session.bufferingChanges.listen((buffering) {
      if (_disposed) return;
      _setBuffering(buffering);
    });
    isBuffering = session.isBuffering;

    isPlaying = session.isPlaying;

    _durationSubscription = session.durations.listen((dur) {
      if (_disposed) return;
      // While transcoding we force the full media duration (MPV's reported
      // duration only covers the segments produced so far). During a swap
      // currentQuality may momentarily still read as Direct Play, so the swap
      // guard has to stand in for it — otherwise the growing HLS duration
      // overwrites the real one and every later position looks out of range.
      // Le fichier est ouvert et son index lu : l'étape entre `play` et la
      // première image.
      if (dur > Duration.zero) _mark('loaded');
      if (_hlsSwapInFlight || currentQuality != null) return;
      duration = dur;
      onDurationChanged();
    });

    _completedSubscription = session.completions.listen((_) {
      if (_disposed) return;
      onCompleted();
    });

    // Le moteur dit les dimensions à sa façon — `videoParams` pour mpv, la
    // taille intrinsèque de l'élément `<video>` sur le web, où mpv n'existe
    // pas. La différence est descendue dans la session : c'en est une entre
    // moteurs, pas entre écrans.
    _videoParamsSubscription = session.videoParamChanges.listen((params) {
      if (_disposed) return;
      final aspect = params.aspect;
      if (aspect == null || aspect <= 0) return;
      // Le décodeur connaît les dimensions : il a lu l'en-tête de la vidéo,
      // pas encore forcément peint une image.
      _mark('decoder');
      videoAspectRatio = aspect;
      _videoParamsReady = true;
      _maybeMarkFirstFrame();
    });

    _failureSubscription = session.failures.listen((failure) {
      if (_disposed) return;
      unawaited(_handleFailure(failure));
    });

    _media = media;
    _apiClient = apiClient;
    _knownDurationSeconds =
        knownDurationSeconds > 0 ? knownDurationSeconds : media.duration;
    if (_knownDurationSeconds > 0 && duration.inSeconds == 0) {
      duration = Duration(seconds: _knownDurationSeconds);
    }
    _onDurationChanged = onDurationChanged;
    _onPositionChanged = onPositionChanged;
    _onPlayingChanged = onPlayingChanged;
    _onQualitySwitchingChanged = onQualitySwitchingChanged;
    _onBufferingChanged = onBufferingChanged;
    _onFirstFrame = onFirstFrame;
    _onTracksChanged = onTracksChanged;
    _onFailure = onFailure;

    // Pas pour le visiteur d'un lien de partage : son média porte l'identifiant
    // d'un autre serveur, qui peut être celui d'un téléchargement d'ici.
    _localFilePath = apiClient.isGuest
        ? null
        : DownloadManager.instance.localVideoPath(media.id);

    // Sans choix transmis par l'épisode qu'on quitte, c'est celui que le
    // compte a retenu pour la série (ADR-0044). La demande part ici pour
    // courir pendant celle du ticket, et se lit juste après.
    _seriesMemory = SeriesTrackMemory.forMedia(apiClient, media);
    final seriesChoice = inheritedPreferences == null
        ? _seriesMemory?.load(cacheFirst: _localFilePath != null)
        : null;

    // La séance s'ouvre ici, avant tout ce qui peut encore échouer : l'accès au
    // flux, l'ouverture du conteneur, le repli en transcodage.
    //
    // Le serveur ne rattache le journal d'une lecture qu'à une séance qu'il
    // connaît déjà (voir `playback_logs.go`). L'ouvrir seulement une fois
    // `play()` passé revenait donc à ne garder de journal que pour les lectures
    // qui ont démarré — c'est-à-dire précisément pas celles qu'on vient y
    // chercher. Une panne au démarrage écrivait sa ligne dans le tampon local,
    // puis la jetait faute de séance à qui la donner.
    //
    // Une ligne d'historique ouverte pour une lecture qui n'a jamais commencé
    // ne traîne pas : `finishHistoryRow` efface ce qui dure moins de trente
    // secondes, sauf quand le journal porte une erreur — ce qui est exactement
    // le cas qu'on veut retrouver.
    _reporter.open(mediaId: media.id, apiClient: apiClient);
    // Les mesures partent avec la séance, pas avec la première image : le temps
    // passé à ouvrir fait partie de ce qu'on veut pouvoir relire.
    _stats.start(session);

    if (_localFilePath == null) {
      final access = await apiClient.openPlaybackAccess(media.id);
      if (_disposed) {
        await access.close();
        return;
      }
      _playbackAccess = access;
      // Un média partagé arrive d'un autre serveur : son nom rejoint ceux
      // qu'on garde en cache DNS, pour les lectures suivantes.
      DnsWarmup.watch([access.origin]);
      _mark('ticket');
    }
    final streamUrl = _directPlaySource(apiClient, media.id);

    if (seriesChoice != null) {
      final stored = await seriesChoice;
      if (_disposed) return;
      if (stored != null) {
        inheritedPreferences = PlayerPlaybackPreferences.fromSeries(stored);
      }
    }

    if (inheritedPreferences != null) {
      _applyInheritedPreferences(inheritedPreferences);
    } else {
      _subtitlesExplicitlyOff = true;
      _selectedSubtitleLang = null;
      _selectedInternalSubId = null;
    }

    // Direct Play is a native-only path. A browser cannot open the containers
    // and audio codecs a private library is actually made of, and the failure is
    // silent — picture, no sound, no message. Rather than open the file and back
    // out of it a moment later, the web waits for the track list and starts
    // straight in HLS, at the source's own resolution.
    if (!_hlsOnly) {
      // Which audio track to load with. The episode being carried over from
      // knows best; otherwise it is the user's standing preference, which lives
      // on this machine and costs nothing to read.
      final preferredAudioLang =
          inheritedPreferences?.audioLang ?? await _loadDefaultAudioLang();
      await _applyPreferredAudioLanguage(preferredAudioLang);

      _mark('prepared');
      // Resolve the resume point BEFORE opening, so mpv can be handed the offset
      // as part of the load itself. Playing from 0 and seeking afterwards meant
      // connecting, probing and buffering at the head of the file, then throwing
      // all of it away for a second connection at the real position — the whole
      // start-up cost paid twice, plus an audible blip from the first seconds.
      //
      // The lookup is already in flight (it starts before init), so this
      // normally costs nothing. If the server is slow to answer, give up on the
      // fast path rather than hold the picture hostage: -1 falls back to the
      // legacy open-then-seek in [startPlayback].
      //
      // A point already known on this device (the home row carries it) makes
      // the server's answer a confirmation rather than a prerequisite: it gets
      // a short head start, then the open goes ahead at the known point. The
      // server can take seconds when it first asks Emby, and missing the 1.5s
      // window used to mean opening at 0 and seeking — the whole start twice.
      var startAt = -1;
      if (resumePositionFuture != null) {
        final hint = provisionalResumeSeconds >= 3 ? provisionalResumeSeconds : 0;
        try {
          startAt = await resumePositionFuture.timeout(hint > 0
              ? const Duration(milliseconds: 400)
              : const Duration(milliseconds: 1500));
        } catch (_) {
          startAt = hint > 0 ? hint : -1;
          debugPrint('Player: reprise pas encore confirmée par le serveur — '
              'ouverture à ${startAt}s');
        }
      } else {
        startAt = 0;
      }
      if (_disposed) return;
      _mark('resume');
      if (startAt > 0) _startup.note('reprise à ${startAt}s');

      try {
        await session.open(
          streamUrl,
          start: startAt > 0 ? Duration(seconds: startAt) : null,
          play: false,
        );
        if (startAt >= 0) {
          _openedAtSeconds = startAt;
          if (startAt > 0) position = Duration(seconds: startAt);
        }
      } catch (e) {
        ClientLog.error(
            "Player: failed to open stream: ${redactPlaybackDiagnostic(e)}");
      }
      _mark('opened');
    }

    if (_disposed) return;
    unawaited(_loadMediaTracksAndPreferences(
      apiClient: apiClient,
      mediaId: media.id,
      inheritedPreferences: inheritedPreferences,
    ));

    if (inheritedPreferences == null || inheritedPreferences.subtitlesOff) {
      try {
        session.setSubtitles(const SubtitleSelection.none());
      } catch (_) {
        // Moteur pas encore prêt : la sélection est réappliquée au chargement.
      }
    }
  }

  /// Ce que le moteur doit ouvrir en Direct Play : le fichier local s'il est
  /// là, l'URL de flux sinon. Un seul endroit décide, pour que le retour depuis
  /// le transcodage retombe sur la même source que l'ouverture initiale.
  String _directPlaySource(ApiClient apiClient, int mediaId) =>
      _localFilePath ??
      apiClient.getStreamUrl(mediaId, access: _playbackAccess);


  Future<void> _waitUntilSeekable() async {
    if (session.duration > Duration.zero) return;

    try {
      await session.durations
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 8));
      return;
    } catch (_) {
      // Durée pas venue à temps : l'attente suivante prend le relais.
    }

    try {
      if (!session.isBuffering) {
        await session.bufferingChanges
            .firstWhere((b) => b)
            .timeout(const Duration(seconds: 3));
      }
      await session.bufferingChanges
          .firstWhere((b) => !b)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 800));
    }
  }

  /// How far the server's resume point may sit from the one the stream was
  /// opened at before it is worth a seek.
  static const _resumeToleranceSeconds = 5;

  /// Starts playback, optionally resuming at an absolute position in the media.
  Future<void> startPlayback({
    required int mediaId,
    required ApiClient apiClient,
    int resumeAtSeconds = 0,
  }) async {
    if (_disposed) return;
    if (_hlsOnly) {
      // On the web the resume point is part of the session: the server was asked
      // to start transcoding at that second, so there is nothing to seek to —
      // and a seek would land outside the window it is producing anyway. When
      // the session is not up yet (it waits on the track list, which normally
      // arrives after this runs), _startWebTranscode is what applies the offset,
      // and it opens with play:true.
      await session.play();
    } else if (currentQuality == null &&
        _openedAtSeconds >= 0 &&
        (resumeAtSeconds - _openedAtSeconds).abs() <= _resumeToleranceSeconds) {
      // Already positioned: init() opened the stream at this second via
      // `Media.start`, which media_kit applies inside mpv's `on_load` hook —
      // i.e. before the file is loaded, so the offset is part of the load
      // instead of a seek that undoes it. Nothing left to do but play. A few
      // seconds off the server's answer (the known point it confirmed) is not
      // worth a second start.
      await session.play();
    } else if (currentQuality == null &&
        _media != null &&
        (resumeAtSeconds > 0 || _openedAtSeconds > 0)) {
      // Fallback when the resume point arrived too late to be part of the open
      // (slow /progress response), or corrected the point it was opened at.
      // Start playing, wait for the first buffering cycle to complete, then
      // seek. Setting the mpv `start` property by hand
      // at this stage does not work with media_kit 1.2.6: open() returns before
      // mpv processes the loadfile command, and the immediate `start=0` reset
      // cancels the resume offset before mpv applies it.
      await session.play();
      await _waitUntilSeekable();
      if (!_disposed) {
        await session.seek(Duration(seconds: resumeAtSeconds));
        position = Duration(seconds: resumeAtSeconds);
      }
    } else {
      await session.play();
    }
    _mark('play');
    _playbackStarted = true;
    if (_pendingPreferenceReapply) {
      _pendingPreferenceReapply = false;
      _reapplySelectionsAfterLoad();
    }
    startHeartbeat(mediaId: mediaId, apiClient: apiClient);
    _auto
      ..enabled = AutoQualityPreference.enabled
      ..start();
    _setPlaying(session.isPlaying);
    _scheduleDeferredSubtitleExtraction();
  }
}
