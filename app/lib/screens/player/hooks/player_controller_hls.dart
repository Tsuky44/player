part of 'use_player_controller.dart';

/// Les sessions HLS : changement de qualité, retour au Direct Play, recherche
/// dans ou hors de ce que la session a déjà encodé, et le démarrage du web,
/// qui ne lit que par elles.
extension PlayerControllerHls on PlayerController {
  /// The second a web session should begin at, or 0.
  ///
  /// Bounded the same way the native path bounds it: a slow /progress response
  /// must not hold the picture hostage, and starting from the beginning is a far
  /// better failure than not starting.
  Future<int> _resolveWebResumeSeconds() async {
    final future = _resumePositionFuture;
    if (future == null) return 0;
    try {
      final seconds = await future.timeout(const Duration(milliseconds: 1500));
      return seconds > 0 ? seconds : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Starts playback on the web, which is always a transcoding session.
  ///
  /// Returns true when a session was started, so the caller stops configuring a
  /// player that is about to be handed a different source.
  Future<bool> _startWebTranscode() async {
    if (!_hlsOnly) return false;
    if (currentQuality != null) return false; // already running
    final tracks = mediaTracks;
    if (tracks == null) return false;

    final height = tracks.video?.height ?? 0;
    final surface = _surfacePixelHeight();
    final quality = webQualityFor(
      sourceHeight: height,
      viewportHeight: surface,
      sourceCodec: tracks.video?.codec ?? '',
    );
    // The resume point has to be part of the session rather than a seek applied
    // to it afterwards: the server transcodes from `?start=N` onwards, and the
    // rest of the film does not exist yet to seek into.
    //
    // This is also the only place it can be applied on the web. Every other
    // platform folds it into the open() that init() performs; a browser cannot
    // open anything until the track list has said which resolution to ask for,
    // and by then startPlayback has already run and found no session to
    // position. It used to depend on which of those two finished first — the
    // track list normally won, and the resume point was simply dropped.
    final startSeconds = await _resolveWebResumeSeconds();
    debugPrint(
        "Player: web session — source ${height}px, surface ${surface}px, "
        "asking $quality from ${startSeconds}s (video=${tracks.video?.codec})");
    await switchToQuality(quality, startSeconds: startSeconds);
    return true;
  }

  /// Height in real pixels of the surface the video will be painted on.
  ///
  /// The player screen fills the window, so the window is the surface. Physical
  /// rather than logical pixels is what matters here: a 1440-logical-pixel window
  /// on a 2× display really does have 2880 rows to fill, and asking for 720p
  /// there would be visibly soft.
  ///
  /// 0 on anything unexpected, which [webQualityFor] reads as "apply no ceiling".
  int _surfacePixelHeight() {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return 0;
      return views.first.physicalSize.height.round();
    } catch (_) {
      return 0;
    }
  }

  // ==================== Quality switching ====================

  /// Le choix fait dans le menu Qualité : [key] est un barreau, ou null pour
  /// le Direct Play. Il l'emporte sur l'adaptation jusqu'à la fin de cette
  /// lecture.
  Future<void> chooseQuality(String? key) {
    _adaptive.noteUserChoice();
    return key == null ? switchToDirectPlay() : switchToQuality(key);
  }

  /// Une mise en mémoire tampon vient de commencer. Si elle fait la preuve que
  /// la connexion ne tient pas le débit, le lecteur descend d'un barreau.
  void _noteStall() {
    if (!AdaptiveQualityPreference.enabled) return;
    // Un fichier sur le disque n'a pas de ligne à accuser, et un tampon vide
    // avant la première image ou pendant un changement de session n'en accuse
    // aucune.
    if (isLocalPlayback || !hasFirstFrame || !isPlaying) return;
    if (isSwitchingQuality || _hlsSwapInFlight) return;
    final ladder = mediaTracks?.qualities ?? const <QualityTier>[];
    if (ladder.isEmpty) return;
    if (!_adaptive.noteStall(DateTime.now())) return;

    final tier = AdaptiveQuality.stepDown(
      ladder: ladder,
      currentKey: currentQuality,
      sourceHeight: mediaTracks?.video?.height ?? 0,
      demandBps: _stats.declaredBitrateBps,
    );
    if (tier == null) return;
    debugPrint('Player: la connexion ne suit pas '
        '(${currentQuality ?? 'direct'}) — passage à ${tier.key}');
    unawaited(switchToQuality(tier.key).then((_) {
      // Annoncé une fois la session ouverte : un serveur qui la refuse laisse
      // la lecture où elle était, et il n'y a alors rien à expliquer.
      if (!_disposed && currentQuality == tier.key) {
        onQualityAdapted?.call(tier);
      }
    }));
  }

  /// Switch transcoding quality (or start transcoding from Direct Play),
  /// resuming at the exact same second. Always shows the loading spinner.
  ///
  /// [startSeconds] overrides that: the first web session of a media has no
  /// current second to preserve, it has a resume point to honour.
  Future<void> switchToQuality(String quality, {int? startSeconds}) async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == quality) return;

    if (currentQuality == null) {
      // Leaving Direct Play: a bitmap track the user picked there was being
      // rendered natively by mpv from the original file. That file is no longer
      // streamed once we transcode, so the choice only survives as a burn-in.
      _hlsBurnedSubTypedIndex =
          _subtitlesExplicitlyOff ? -1 : _burnIndexFor(_selectedSubtitleLang);
    }
    await _openHlsSession(
      quality: quality,
      startSeconds: startSeconds ?? position.inSeconds,
    );
  }

  /// Reload the HLS session at a new absolute position (large seeks in HLS mode,
  /// where segments outside the sliding window no longer exist).
  Future<void> reloadHlsAtPosition(int newPositionSeconds) async {
    if (_media == null || _apiClient == null || currentQuality == null) return;
    // Pendant un changement de qualité, la qualité visée est celle qui arrive,
    // pas celle qui s'en va.
    await _openHlsSession(
        quality: _hlsQualityInFlight ?? currentQuality!,
        startSeconds: newPositionSeconds);
  }

  /// Core HLS (re)launch: ask the server for a fresh session, open its master
  /// playlist directly (mpv handles child playlists/segments), force the full
  /// duration and re-apply the audio/subtitle selection.
  Future<void> _openHlsSession({
    required String quality,
    required int startSeconds,
  }) async {
    if (_media == null || _apiClient == null || _disposed) return;
    _adaptive.noteDisturbance(DateTime.now());
    if (_hlsSwapInFlight) {
      // Une session est déjà en train de s'ouvrir. Cette demande-ci était
      // ignorée : un second saut pendant l'ouverture était perdu, et la lecture
      // reprenait au premier endroit cliqué. Elle est gardée — la dernière
      // gagne — et servie dès que l'ouverture en cours se termine.
      _pendingHlsOpen = (quality: quality, startSeconds: startSeconds);
      position = Duration(seconds: startSeconds);
      _onPositionChanged?.call();
      return;
    }

    isSwitchingQuality = true;
    _hlsSwapInFlight = true;
    _hlsQualityInFlight = quality;
    // Move the reported position to the target straight away. The rebuild takes
    // a few seconds, during which the swap guard (rightly) suppresses mpv's
    // position events — so without this the timeline would keep showing where
    // playback was BEFORE the seek, and the user cannot see what they clicked
    // until the video finally starts.
    position = Duration(seconds: startSeconds);
    _onPositionChanged?.call();
    _onQualitySwitchingChanged?.call();

    final mediaId = _media!.id;
    final oldSessionId = _hlsSessionId;
    final api = _apiClient!;
    PlaybackAccess? access = _playbackAccess;
    HlsSession? pendingSession;
    var adopted = false;

    try {
      if (access == null) {
        access = await api.openPlaybackAccess(mediaId);
        if (_disposed) {
          await access.close();
          return;
        }
        _playbackAccess = access;
      }
      final hls = await api.startHlsSession(
        mediaId,
        quality,
        startSeconds: startSeconds,
        audioIndex: _selectedAudioIndex,
        burnSubtitleIndex: _hlsBurnedSubTypedIndex,
        access: access,
      );
      pendingSession = hls;
      if (_disposed) return;

      // Tear down the previous session only once the new one is ready.
      if (oldSessionId != null) {
        _apiClient!
            .destroyHlsSession(mediaId, oldSessionId, access: _playbackAccess);
      }

      await session.applyStreamingTuning(PlaybackProfiles.current);
      // The session publishes exactly the renditions the server was asked for,
      // and the selection among them is made by index through _hlsAudioMap. A
      // language preference left over from Direct Play would only give mpv a
      // second, disagreeing opinion about which one to play.
      await _applyPreferredAudioLanguage(null);
      if (_disposed) return;
      // No longer a Direct Play stream opened at a known second.
      _openedAtSeconds = -1;
      await session.open(hls.masterUrl, play: true);
      if (_disposed) return;
      // Two defects to undo on web. media_kit trusts `canPlayType` to decide
      // whether the browser speaks HLS — Chromium says "maybe" and cannot — so
      // hls.js has to be put back in charge. And it builds a fresh hls.js per
      // open() without ever destroying the last, so abandoned instances pile up
      // on the same <video>, each still running its loaders.
      WebPlayback.adoptHlsSession(hls.masterUrl);

      // _hlsStartOffset feeds directly into the position listener
      // (`pos + Duration(seconds: _hlsStartOffset)`). Setting it BEFORE
      // player.open() resolves left a window where a straggler position event
      // from the OLD stream (still in flight from mpv/media_kit's async
      // native side) got combined with the NEW target offset — producing an
      // absolute position that belongs to neither stream. On a big seek this
      // is not a one-frame flicker: it can read as "landed minutes away from
      // where I clicked". Every field the position/seek math depends on is
      // assigned only once we know player.open() has actually taken effect.
      _hlsSessionId = hls.sessionId;
      _hlsVideoMode = hls.videoMode;
      adopted = true;
      currentQuality = quality;
      _hlsStartOffset = startSeconds;
      _hlsAudioMap = hls.audioMap;
      // Trust the server: a track it could not burn in comes back as -1.
      _hlsBurnedSubTypedIndex = hls.burnedSubtitle;
      _adoptLiveSubtitles(hls.subtitles);
      _hlsRetainSeconds = hls.retainSeconds;

      // Duration first, then reopen the gate: position events resume against a
      // coherent (offset, duration) pair rather than a half-updated one.
      _forceDuration(hls.totalDuration);
      position = Duration(seconds: startSeconds);
      _hlsSwapInFlight = false;
      _onPositionChanged?.call();

      _reapplySelectionsAfterLoad();
      _hideLoadingAfterBuffer();

      // Kick off .vtt extraction in the background and poll until ready so a
      // language picked in Direct Play (or in the menu) attaches without reload.
      _ensureSubtitlesExtracted();
      if (_selectedSubtitleLang != null &&
          !_isSubtitleReady(_selectedSubtitleLang!)) {
        _startSubtitleWatch();
      }
    } catch (e) {
      debugPrint(
          "Player: failed to open HLS session: ${redactPlaybackDiagnostic(e)}");
      isSwitchingQuality = false;
      // Must reopen even on failure: leaving the gate shut would freeze the
      // reported position for the rest of the session.
      _hlsSwapInFlight = false;
      if (!_disposed) _onQualitySwitchingChanged?.call();
    } finally {
      _hlsQualityInFlight = null;
      if (!adopted && pendingSession != null) {
        await api.destroyHlsSession(mediaId, pendingSession.sessionId,
            access: access);
      }
      _openPendingHlsSession();
    }
  }

  /// Sert la demande arrivée pendant la dernière ouverture, s'il y en a une.
  void _openPendingHlsSession() {
    final pending = _pendingHlsOpen;
    _pendingHlsOpen = null;
    if (pending == null || _disposed || _hlsSwapInFlight) return;
    unawaited(_openHlsSession(
      quality: pending.quality,
      startSeconds: pending.startSeconds,
    ));
  }

  /// Switch back to Direct Play from HLS, resuming at the same second.
  Future<void> switchToDirectPlay() async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == null) return;

    final savedSeconds = position.inSeconds;
    _adaptive.noteDisturbance(DateTime.now());
    isSwitchingQuality = true;
    _onQualitySwitchingChanged?.call();

    await _destroyHlsSession();

    currentQuality = null;
    _hlsStartOffset = 0;
    _hlsAudioMap = const [];
    // Direct Play renders bitmap subtitles natively; nothing is burned in.
    _hlsBurnedSubTypedIndex = -1;
    duration = Duration.zero;

    await session.applyDirectPlayTuning(PlaybackProfiles.current);
    // Back to the file's own tracks: load straight onto the language the user
    // was listening to, instead of the container default followed by a switch.
    await _applyPreferredAudioLanguage(_selectedAudioLang);
    final streamUrl = _directPlaySource(_apiClient!, _media!.id);
    // Open straight at the position the HLS session was left at. The previous
    // shape — open at 0, wait out a full buffering cycle, seek, wait again —
    // buffered the head of the file for nothing and made every switch back to
    // Direct Play take several seconds of spinner.
    _openedAtSeconds = savedSeconds > 0 ? savedSeconds : 0;
    await session.open(
      streamUrl,
      start: savedSeconds > 0 ? Duration(seconds: savedSeconds) : null,
      play: true,
    );
    if (savedSeconds > 0) {
      position = Duration(seconds: savedSeconds);
      _onPositionChanged?.call();
    }

    _reapplySelectionsAfterLoad();

    isSwitchingQuality = false;
    _onQualitySwitchingChanged?.call();
  }

  /// Small tolerance for forward seeks, used only as a floor under the player's
  /// own buffered position so a one-second rounding difference does not force a
  /// full session rebuild.
  static const _hlsForwardSeekTolerance = 2;

  /// Hard ceiling on how far ahead an in-session forward seek may land.
  ///
  /// Sized against the server's just-in-time window (32s), because that is the
  /// most the encoder is ever allowed to run ahead — anything past it provably
  /// does not exist yet. Rebuilding instead costs a measured 3-6s, so this
  /// caps the worst case at "briefly wait for content already being written"
  /// rather than "wait for two minutes of video to be encoded in order".
  static const _maxForwardCatchUpSeconds = 30;

  /// Whether [absoluteSeconds] can be reached by seeking inside the running HLS
  /// session, without transcoding anything new.
  ///
  /// Backwards is decided structurally, forwards is decided by measurement —
  /// and the difference matters:
  ///
  ///   - Backwards, down to the session's own start offset, is always safe. The
  ///     playlist is append-only (EXT-X-PLAYLIST-TYPE:EVENT) and segments are
  ///     never deleted, so anything the playhead has already passed is still on
  ///     disk. This is the case worth optimising: rewinding used to throw away
  ///     the whole transcode and start over.
  ///
  ///   - Forwards is capped by what the player has ACTUALLY buffered. It is
  ///     tempting to assume the server's just-in-time window (~32s ahead) is
  ///     always filled, but that only holds while the encoder outruns playback.
  ///     A CPU-bound 4K transcode sits at roughly real-time or below, so that
  ///     buffer frequently does not exist — and seeking into it lands on
  ///     segments that were never produced, leaving the player waiting forever
  ///     on files that will not arrive until the encoder eventually catches up.
  ///     Asking the player how far it has really buffered removes the guess.
  ///
  /// When the buffer reading is unavailable or zero, forward seeks simply fall
  /// back to rebuilding the session — the conservative behaviour.
  bool canSeekWithinSession(int absoluteSeconds) {
    if (currentQuality == null) return true;
    // Before this session's timeline begins: unreachable without a new session.
    if (absoluteSeconds < _hlsStartOffset) return false;
    // Behind what the server still keeps: those segments are gone.
    if (absoluteSeconds <
        retainedFloorSeconds(
          startOffset: _hlsStartOffset,
          bufferedEnd: _bufferedAbsoluteSeconds(),
          retainSeconds: _hlsRetainSeconds,
        )) {
      return false;
    }

    if (absoluteSeconds <= position.inSeconds) return true;

    // Two independent limits, and the seek must satisfy BOTH.
    //
    // The encoder writes segments strictly in order, so an in-session forward
    // seek is only instant if the target is already on disk. Overshoot it and
    // the player waits for everything in between to be encoded — for a jump of
    // a couple of minutes that is far worse than the 3-6s a fresh session costs,
    // and it is what "I have to wait for it to do it all" describes.
    //
    //   - the player's own cache end, which is what is genuinely downloaded;
    //   - a hard ceiling, so a cache reading that is optimistic or stale can
    //     never authorise a jump into content nobody has encoded yet.
    final ceiling = position.inSeconds + _maxForwardCatchUpSeconds;
    final buffered = _bufferedAbsoluteSeconds();
    final reachable = buffered < ceiling ? buffered : ceiling;
    return absoluteSeconds <= reachable + _hlsForwardSeekTolerance;
  }

  /// Absolute second up to which the player currently holds buffered media.
  int _bufferedAbsoluteSeconds() {
    try {
      final buffered = session.bufferedAhead.inSeconds;
      if (buffered <= 0) return position.inSeconds;
      return buffered + _hlsStartOffset;
    } catch (_) {
      return position.inSeconds;
    }
  }

  /// Seek to an absolute position in the media.
  ///
  /// In HLS this rebuilds the session only when the target is outside what the
  /// current one can serve. Rewinding — the common case, and previously a full
  /// re-transcode with a spinner — is now a plain seek through already-produced
  /// segments.
  Future<void> seekToAbsoluteSeconds(int absoluteSeconds) async {
    final target = absoluteSeconds < 0 ? 0 : absoluteSeconds;
    _adaptive.noteDisturbance(DateTime.now());

    if (currentQuality == null) {
      await session.seek(Duration(seconds: target));
      return;
    }

    final within = canSeekWithinSession(target);
    // Logs the whole decision, because "seek does nothing" and "seek rebuilds
    // the session" look identical from the outside: it shows whether a stall is
    // a seek that stayed inside a session it should have left, or a rebuild
    // that is simply slow.
    debugPrint("SEEK: target=${target}s pos=${position.inSeconds}s "
        "offset=${_hlsStartOffset}s buffered=${_bufferedAbsoluteSeconds()}s "
        "-> ${within ? 'seek in session' : 'rebuild session'}");

    if (!within) {
      await reloadHlsAtPosition(target);
      return;
    }
    // Reflect the target before awaiting mpv, so the bar tracks the click even
    // when the seek itself takes a moment to settle.
    position = Duration(seconds: target);
    _onPositionChanged?.call();
    await session.seek(Duration(seconds: target - _hlsStartOffset));
  }

  /// [seekToAbsoluteSeconds] à la milliseconde près.
  ///
  /// Pour « Regarder ensemble », où tomber sur la seconde entière laissait
  /// jusqu'à une demi-seconde d'écart entre deux appareils. Une cible hors de
  /// la session HLS la reconstruit à la seconde : le rattrapage fin se fait
  /// ensuite par la vitesse.
  Future<void> seekToAbsolutePosition(Duration target) async {
    if (target.isNegative) target = Duration.zero;
    _adaptive.noteDisturbance(DateTime.now());
    if (currentQuality == null) {
      position = target;
      _onPositionChanged?.call();
      await session.seek(target);
      return;
    }
    if (!canSeekWithinSession(target.inSeconds)) {
      await reloadHlsAtPosition(target.inSeconds);
      return;
    }
    position = target;
    _onPositionChanged?.call();
    await session.seek(target - Duration(seconds: _hlsStartOffset));
  }

  // ==================== HLS helpers ====================

  void _forceDuration(double totalDurationSeconds) {
    if (totalDurationSeconds <= 0) return;
    duration = Duration(seconds: totalDurationSeconds.round());
    unawaited(session.overrideDuration(
      Duration(milliseconds: (totalDurationSeconds * 1000).round()),
    ));
    _onDurationChanged?.call();
  }

  /// Hide the spinner once buffering has started and then stopped (the stream
  /// is actually playing), with a safety timeout.
  void _hideLoadingAfterBuffer() {
    StreamSubscription? sub;
    var sawBuffering = false;
    sub = session.bufferingChanges.listen((isBuffering) {
      if (isBuffering) {
        sawBuffering = true;
      } else if (sawBuffering) {
        isSwitchingQuality = false;
        _onQualitySwitchingChanged?.call();
        sub?.cancel();
      }
    });
    Timer(const Duration(seconds: 15), () {
      sub?.cancel();
      if (isSwitchingQuality) {
        isSwitchingQuality = false;
        _onQualitySwitchingChanged?.call();
      }
    });
  }

  Future<void> _destroyHlsSession() async {
    _hlsLiveSubtitles = null;
    _hlsRetainSeconds = null;
    liveSubtitles.stop();
    if (_hlsSessionId == null || _media == null || _apiClient == null) return;
    await _apiClient!
        .destroyHlsSession(_media!.id, _hlsSessionId!, access: _playbackAccess);
    _hlsSessionId = null;
  }
}
