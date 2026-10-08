part of 'use_player_controller.dart';

/// Les pistes audio et les sous-titres : la liste du serveur, le choix en
/// cours, son application au moteur, et l'extraction de fond qui fournit les
/// sous-titres aux serveurs d'avant l'ADR-0031.
extension PlayerControllerTracks on PlayerController {
  Future<void> _loadMediaTracksAndPreferences({
    required ApiClient apiClient,
    required int mediaId,
    required PlayerPlaybackPreferences? inheritedPreferences,
  }) async {
    try {
      final tracks = await _loadTracks(apiClient, mediaId);
      if (_disposed || tracks == null) return;
      // Arrivée pendant le démarrage, la liste peut faire changer de piste
      // audio — ce qui relance le chargement : la ligne doit le situer.
      _mark('tracks');

      mediaTracks = tracks;

      // La piste d'abord : une session HLS s'ouvre avec la piste demandée
      // (`?audio=N`). Choisie après, le web partait sur la première piste du
      // fichier — l'anglais d'un film réglé en français.
      final defaultLang = await _loadDefaultAudioLang();
      if (_disposed) return;
      if (inheritedPreferences != null) {
        _applyInheritedPreferences(inheritedPreferences,
            defaultAudioLang: defaultLang);
      } else if (tracks.audio.isNotEmpty) {
        _selectedAudioIndex = PlaybackPreferencesStorage.pickAudioIndex(
          tracks.audio,
          defaultLang,
        );
      }

      // The track list is what carries the source resolution, so this is the
      // first moment the web can pick a quality. Nothing is playing yet on that
      // platform — init deliberately opened nothing.
      if (await _startWebTranscode()) return;

      if (_directPlayCannotDecodeAudio(_selectedAudioIndex)) {
        _notifyTracksChanged();
        await _transcodeForUndecodableAudio();
        return;
      }

      _pendingPreferenceReapply = true;
      _notifyTracksChanged();
      // `isPlaying` seul ne suffit pas : ExoPlayer le dit faux tant qu'il met
      // en tampon. Une liste arrivée à ce moment-là, après `startPlayback`,
      // n'était plus appliquée par personne — l'épisode suivant démarrait sans
      // le sous-titre hérité.
      if (_playbackStarted || session.isPlaying) {
        _pendingPreferenceReapply = false;
        _reapplySelectionsAfterLoad();
        _scheduleDeferredSubtitleExtraction();
      }
    } catch (e) {
      debugPrint(
          "Player: failed to load media tracks: ${redactPlaybackDiagnostic(e)}");
    }
  }

  /// La liste des pistes, du serveur ou du disque.
  ///
  /// Pour un média téléchargé, la copie locale passe devant : elle est
  /// instantanée, elle décrit exactement le fichier qu'on est en train de lire,
  /// et surtout elle existe hors ligne — où l'appel réseau ne ferait
  /// qu'attendre son délai avant de laisser les menus vides.
  Future<MediaTracks?> _loadTracks(ApiClient apiClient, int mediaId) async {
    if (_localFilePath != null) {
      final offline = DownloadManager.instance.offlineTracks(mediaId);
      if (offline != null) return MediaTracks.fromJson(offline);
    }
    try {
      return await apiClient.getMediaTracks(mediaId);
    } catch (e) {
      final offline = DownloadManager.instance.offlineTracks(mediaId);
      if (offline != null) return MediaTracks.fromJson(offline);
      rethrow;
    }
  }

  /// Le WebVTT d'une piste, local d'abord.
  ///
  /// [start] n'est non nul qu'en transcodage, qui suppose déjà un serveur : la
  /// copie locale, dont les temps sont ceux du fichier entier, ne conviendrait
  /// pas à une session HLS commençant en cours de route.
  Future<String> _loadSubtitleVtt(int mediaId, String lang, int start) async {
    if (_localFilePath != null && start == 0) {
      final local =
          await DownloadManager.instance.offlineSubtitle(mediaId, lang);
      if (local != null && local.contains('-->')) return local;
    }
    return _apiClient!.fetchSubtitleContent(mediaId, lang,
        start: start, access: _playbackAccess);
  }

  /// Tells mpv which audio language to select when it loads the next file.
  ///
  /// Without this, the track list has to come back from the server before the
  /// choice can be made, so playback starts on whatever the container marked as
  /// default and switches a second later — and switching audio mid-playback
  /// makes mpv refill the demuxer for the new stream, which is audible.
  ///
  /// [code] is a normalized two-letter code, or null to let the file decide.
  /// Passing null must still write the property: on a reused engine, silence
  /// here would mean inheriting the previous media's preference.
  Future<void> _applyPreferredAudioLanguage(String? code) async {
    await session.setPreferredAudioLanguages(_alangPriorities(code));
  }

  /// Expands a two-letter code into the tags real files actually carry.
  ///
  /// A Matroska track is usually tagged with an ISO 639-2 code (`fre`, `ger`)
  /// and sometimes with a plain English name, none of which match the two-letter
  /// form on their own. Every spelling is offered at once, most likely first,
  /// rather than guessed at.
  static List<String> _alangPriorities(String? code) {
    if (code == null || code.isEmpty) return const [];
    const alternates = {
      'fr': ['fre', 'fra', 'french'],
      'en': ['eng', 'english'],
      'es': ['spa', 'esp', 'spanish'],
      'de': ['ger', 'deu', 'german'],
      'it': ['ita', 'italian'],
      'pt': ['por', 'portuguese'],
      'ja': ['jpn', 'japanese'],
      'ru': ['rus', 'russian'],
      'zh': ['chi', 'zho', 'chinese'],
      'ar': ['ara', 'arabic'],
      'nl': ['nld', 'dut', 'dutch'],
      'ko': ['kor', 'korean'],
    };
    return [code, ...?alternates[code]];
  }

  void _scheduleDeferredSubtitleExtraction() {
    if (_autoExtractStarted || _disposed) return;
    // Direct Play lit les sous-titres du fichier lui-même : les .vtt ne servent
    // qu'au HLS, qui lance l'extraction à son ouverture. Les préparer ici
    // relisait le fichier entier sur le disque du serveur — des minutes pour
    // un remux — et une reprise lancée pendant ce temps démarrait en quinze
    // secondes au lieu de deux.
    if (currentQuality == null && !_hlsOnly) return;
    if (!_hasPendingSubtitles()) return;

    _deferredSubtitleExtractTimer?.cancel();
    _deferredSubtitleExtractTimer = Timer(PlayerController._subtitleExtractDelay, () {
      if (_disposed) return;
      _ensureSubtitlesExtracted();
    });
  }

  void _notifyTracksChanged() {
    _onTracksChanged?.call();
    if (!_tracksStreamController.isClosed) {
      _tracksStreamController.add(null);
    }
  }

  /// Retient les pistes que la nouvelle session écrit, et les marque prêtes
  /// dans le catalogue : toute la mécanique d'extraction s'éteint alors pour
  /// elles d'elle-même.
  ///
  /// Ce qui était affiché s'efface tout de suite : ses répliques sont sur
  /// l'horloge de la session précédente, et elles tomberaient au mauvais moment
  /// sur celle-ci jusqu'à ce que la sélection soit réappliquée.
  void _adoptLiveSubtitles(List<LiveSubtitleSource>? sources) {
    liveSubtitles.stop();
    _hlsLiveSubtitles = sources;
    final tracks = mediaTracks;
    if (sources == null || tracks == null) return;
    mediaTracks = withLiveSubtitles(tracks, sources);
    _notifyTracksChanged();
  }

  MediaTracks _withLiveSubtitles(MediaTracks tracks) {
    final sources = _hlsLiveSubtitles;
    if (sources == null || currentQuality == null) return tracks;
    return withLiveSubtitles(tracks, sources);
  }

  /// Canonical track for a language key, or null when the media has no such key.
  MediaSubtitleTrack? _trackForLang(String lang) {
    for (final s in mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[]) {
      if (s.lang == lang) return s;
    }
    return null;
  }

  bool _isSubtitleReady(String lang) {
    final track = _trackForLang(lang);
    if (track == null) return false;
    // Bitmap tracks are never extracted — they are burned in on demand — so they
    // are usable the moment the media is known.
    if (track.image) return true;
    return track.ready;
  }

  bool _hasPendingSubtitles() {
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    // A partial track still has work outstanding: the server is completing it.
    return subs.any((s) => !s.ready || s.partial);
  }

  /// True when [lang] is currently served from a head-only extraction. The cues
  /// stop partway through the media, so the track must be re-attached once the
  /// server finishes the complete pass.
  bool _isSubtitlePartial(String lang) {
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    for (final s in subs) {
      if (s.lang == lang) return s.partial;
    }
    return false;
  }

  Future<void> _refreshMediaTracks() async {
    if (_media == null || _apiClient == null) return;
    try {
      mediaTracks =
          _withLiveSubtitles(await _apiClient!.getMediaTracks(_media!.id));
      _notifyTracksChanged();
    } catch (e) {
      debugPrint(
          "SUB: failed to refresh tracks: ${redactPlaybackDiagnostic(e)}");
    }
  }

  String _subtitleSignature(String lang) =>
      '$lang|${_isSubtitlePartial(lang) ? 'head' : 'full'}|$_hlsStartOffset';

  /// Refreshes the canonical track list and, when a subtitle language is already
  /// chosen, attaches it as soon as its .vtt becomes ready — no HLS reload.
  Future<void> _onSubtitlesUpdated({bool applyIfSelected = true}) async {
    await _refreshMediaTracks();
    if (applyIfSelected &&
        !_subtitlesExplicitlyOff &&
        _selectedSubtitleLang != null &&
        currentQuality != null &&
        _isSubtitleReady(_selectedSubtitleLang!)) {
      final signature = _subtitleSignature(_selectedSubtitleLang!);
      if (signature != _attachedSubtitleSignature) {
        _applySubtitleSelection();
      }
    }
    if (!_hasPendingSubtitles()) {
      _stopSubtitleWatch();
    }
  }

  void _startSubtitleWatch() {
    if (_subtitleWatchTimer != null) return;
    _subtitleWatchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) {
        _stopSubtitleWatch();
        return;
      }
      _onSubtitlesUpdated();
    });
  }

  void _stopSubtitleWatch() {
    _subtitleWatchTimer?.cancel();
    _subtitleWatchTimer = null;
  }

  /// Triggers a one-shot, non-blocking background subtitle extraction when any
  /// text subtitle is still missing its .vtt. When tracks flip to ready the
  /// active selection is applied automatically in HLS — no session reload.
  void _ensureSubtitlesExtracted() {
    if (_autoExtractStarted) return;
    final api = _apiClient;
    final media = _media;
    if (api == null || media == null) return;
    if (!_hasPendingSubtitles()) return;

    _autoExtractStarted = true;
    _isExtractingSubtitles = true;
    _startSubtitleWatch();
    debugPrint("SUB: background extraction started for media ${media.id}");
    api.forceMediaSubtitleExtract(media.id, force: false).then((_) async {
      _isExtractingSubtitles = false;
      if (_disposed) return;
      await _onSubtitlesUpdated();
      debugPrint(
          "SUB: background extraction done, ${mediaTracks?.subtitles.length ?? 0} tracks");
    }).catchError((e) {
      _isExtractingSubtitles = false;
      debugPrint(
          "SUB: background extraction failed: ${redactPlaybackDiagnostic(e)}");
    });
  }
  // ==================== Audio / subtitle selection ====================

  /// Select an audio track by canonical index.
  ///
  ///   - Direct Play: switch natively and instantly (all tracks are present).
  ///   - HLS: the session publishes every audio track as a rendition of one
  ///     group, so this is also just an mpv track switch — instant, no spinner,
  ///     no re-transcode. Only a track the session did not publish (a file with
  ///     more languages than the rendition cap) needs a fresh session.
  Future<void> switchAudioTrack(int index) async {
    if (mediaTracks == null) return;
    if (index < 0 || index >= mediaTracks!.audio.length) return;
    if (index == _selectedAudioIndex) return;
    // Une piste qui change recharge le tampon, sans que la ligne y soit pour
    // rien.
    _noteDisturbance();
    _selectedAudioIndex = index;
    _carriedAudioLang = null;
    final chosenLang = _selectedAudioLang;
    if (chosenLang != null) _seriesMemory?.rememberAudio(chosenLang);

    // A browser offers no audio-track API over a media stream, and media_kit's
    // web setAudioTrack only accepts a URI — the rendition switch that is free
    // on desktop simply does nothing here. The server already takes the wanted
    // track as `?audio=N` at session start, so the switch is a new session:
    // ~2s of spinner instead of instant, but it actually changes the language.
    if (AppPlatform.isWeb) {
      if (currentQuality == null) {
        await _startWebTranscode();
      } else {
        await reloadHlsAtPosition(position.inSeconds);
      }
      return;
    }
    if (_directPlayCannotDecodeAudio(index)) {
      await _transcodeForUndecodableAudio();
      return;
    }
    if (currentQuality != null && _playerAudioPosition(index) == null) {
      await reloadHlsAtPosition(position.inSeconds);
      return;
    }
    _applyAudioSelection();
  }

  /// Si la piste [index] serait muette en Direct Play.
  ///
  /// Le moteur local la liste et la sélectionne sans broncher — le démuxeur la
  /// connaît — puis n'a rien pour la décoder : l'image défile, sans son et sans
  /// erreur. C'est le cas du TrueHD (Atmos compris) sous mpv, et du TrueHD, du
  /// DTS ou de l'(E-)AC-3 sous ExoPlayer quand l'appareil n'a ni décodeur ni
  /// passthrough pour eux.
  bool _directPlayCannotDecodeAudio(int index) {
    if (_hlsOnly || currentQuality != null) return false;
    final audio = mediaTracks?.audio ?? const <MediaAudioTrack>[];
    if (index < 0 || index >= audio.length) return false;
    return !PlaybackCapabilitiesResolver.current
        .decodesInDirectPlay(audio[index].codec);
  }

  /// Ce qu'on fait d'une panne du moteur.
  ///
  /// Une panne après la première image ne se rattrape pas ici : la lecture a
  /// démarré, et les chemins de reprise — relais, reconnexion, rechargement
  /// HLS — ont déjà leurs propres déclencheurs. Ce qui manquait est l'autre
  /// cas : une panne *pendant* le démarrage, qui sur Android ne laissait rien
  /// voir avant le délai de vingt-cinq secondes, et qui pour un conteneur
  /// illisible ne laissait rien voir du tout — le repli en transcodage que
  /// [PlaybackFailureKind.unsupported] nomme n'était branché nulle part.
  Future<void> _handleFailure(PlaybackFailure failure) async {
    if (hasFirstFrame) {
      debugPrint('Player: panne en cours de lecture — $failure');
      return;
    }

    // Ce que l'appareil ne décode pas, le serveur le décode : c'est
    // exactement ce que fait déjà [_transcodeForUndecodableAudio] pour une
    // piste audio muette, à la résolution de la source pour que l'image reste
    // recopiée. Une seule tentative — un transcodage qui échoue à son tour est
    // une vraie panne, pas un cas à rattraper une deuxième fois.
    //
    // La liste de pistes n'est pas attendue : elle se charge en parallèle de
    // l'ouverture, et un conteneur refusé l'est souvent avant qu'elle arrive.
    // Sans hauteur, `qualityForSourceHeight` rend le palier 1080p, que tous les
    // serveurs offrent — se tromper de palier laisse une lecture, l'attendre
    // n'en laisse aucune.
    if (failure.kind == PlaybackFailureKind.unsupported &&
        currentQuality == null) {
      final quality = qualityForSourceHeight(mediaTracks?.video?.height ?? 0);
      debugPrint('Player: Direct Play refusé ($failure) — repli HLS $quality');
      _directPlayRuledOut = true;
      _autoCeilingKey = quality;
      try {
        await switchToQuality(quality);
        return;
      } catch (e) {
        debugPrint(
            'Player: repli HLS impossible : ${redactPlaybackDiagnostic(e)}');
      }
    }

    ClientLog.error('Player: démarrage abandonné — $failure');
    startupFailure = failure;
    // Maintenant, pendant que la séance ouverte par `open()` est encore vivante
    // côté serveur — voir [PlaybackReporter.flushLogs].
    _reporter.flushLogs(_apiClient);
    _onFailure?.call();
  }

  /// Passe en HLS à la résolution de la source, pour que le serveur décode la
  /// piste que le moteur local ne sait pas lire.
  ///
  /// La résolution d'origine est ce qui laisse l'image recopiée plutôt que
  /// ré-encodée : seul l'audio coûte alors quelque chose au serveur.
  Future<void> _transcodeForUndecodableAudio() async {
    final track = mediaTracks!.audio[_selectedAudioIndex];
    final quality = qualityForSourceHeight(mediaTracks!.video?.height ?? 0);
    debugPrint("Player: ${track.codec} illisible en Direct Play "
        "(${PlaybackCapabilitiesResolver.current.label}) — HLS $quality");
    // L'Auto ne ramènera pas la lecture sur une piste muette.
    _directPlayRuledOut = true;
    _autoCeilingKey = quality;
    await switchToQuality(quality);
  }

  /// Turn subtitles on (first available track) or off.
  Future<void> toggleSubtitles() async {
    if (!_subtitlesExplicitlyOff &&
        (_selectedSubtitleLang != null || _selectedInternalSubId != null)) {
      await setSubtitle(null);
      return;
    }

    if (currentQuality == null) {
      final tracks = session.subtitleTracks;
      for (final track in tracks) {
        if (track.id == 'no' || track.id == 'auto') continue;
        selectInternalSubtitle(track);
        return;
      }
    }

    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    if (subs.isEmpty) return;

    final ready = subs.where((s) => s.ready).toList();
    final pick = ready.isNotEmpty ? ready.first : subs.first;
    await setSubtitle(pick.lang);
  }

  /// Select a subtitle by language code, or null to disable. Used by the HLS
  /// menu (external WebVTT). In Direct Play the embedded tracks are used instead
  /// via [selectInternalSubtitle], so this is the canonical/HLS path.
  ///
  /// If the .vtt is not ready yet, extraction is triggered and the track is
  /// attached automatically as soon as it becomes available — no HLS reload.
  /// Bitmap stream the transcoder must paint into the video to show [lang], or
  /// -1 when the language needs no burn-in (text track, or subtitles off).
  int _burnIndexFor(String? lang) {
    if (lang == null || lang.isEmpty) return -1;
    final track = _trackForLang(lang);
    if (track == null || !track.image) return -1;
    return track.typedIndex;
  }

  Future<void> setSubtitle(String? lang) async {
    if (_media == null || _apiClient == null) return;
    _carriedSubtitle = null;
    _selectedSubtitleLang = lang;
    _selectedInternalSubId = null;
    _subtitlesExplicitlyOff = lang == null || lang.isEmpty;
    _rememberSubtitleChoice();

    // While transcoding, a bitmap track lives in the picture itself, so turning
    // one on — or off, or swapping it for another — changes what has to be
    // encoded. That is the only subtitle change that costs a new session; text
    // tracks stay out of band and switch instantly.
    if (currentQuality != null) {
      final wanted = _burnIndexFor(lang);
      if (wanted != _hlsBurnedSubTypedIndex) {
        _hlsBurnedSubTypedIndex = wanted;
        await reloadHlsAtPosition(position.inSeconds);
        return;
      }
    }

    if (lang == null || lang.isEmpty) {
      _applySubtitleSelection();
      return;
    }

    if (currentQuality != null && !_isSubtitleReady(lang)) {
      _ensureSubtitlesExtracted();
      _startSubtitleWatch();
      return;
    }

    _applySubtitleSelection();
  }

  /// Direct Play: select one of the MKV's embedded subtitle tracks natively and
  /// remember it (mpv id + the server's canonical language key) so the choice
  /// survives a reload and carries over to HLS without the user ever seeing the
  /// source change.
  void selectInternalSubtitle(PlaybackTrack track) {
    final isOff = track.id == 'no';
    _carriedSubtitle = null;
    _selectedInternalSubId = isOff ? null : track.id;
    _selectedSubtitleLang = isOff ? null : _canonicalLangForEmbedded(track);
    _subtitlesExplicitlyOff = isOff;
    _rememberSubtitleChoice();
    try {
      session.setSubtitles(SubtitleSelection.track(track));
    } catch (_) {
      // Le choix est retenu : il est réappliqué au prochain chargement.
    }
  }

  List<PlaybackTrack> _realAudioTracks() =>
      session.audioTracks.where((t) => t.id != 'auto' && t.id != 'no').toList();

  /// Position of a canonical audio index in the player's track list.
  ///
  /// Direct Play enumerates the file's own tracks, so the canonical index is the
  /// position. HLS enumerates only the renditions the session published, so the
  /// server's audio map translates between the two. Returns null when the track
  /// is not part of the current session.
  int? _playerAudioPosition(int canonicalIndex) {
    if (currentQuality == null) return canonicalIndex;
    final pos = _hlsAudioMap.indexOf(canonicalIndex);
    return pos < 0 ? null : pos;
  }

  void _applyAudioSelection() {
    final real = _realAudioTracks();
    if (real.isEmpty) return;
    final pos = _playerAudioPosition(_selectedAudioIndex);
    if (pos == null) return; // not published by this session
    final i = pos.clamp(0, real.length - 1);
    try {
      session.setAudioTrack(real[i]);
    } catch (_) {
      // Piste refusée par le moteur : la lecture garde celle qu'elle a.
    }
  }

  void _applySubtitleSelection() {
    // Direct Play is served entirely by the MKV's embedded subtitles: we never
    // inject external WebVTT here, so the user never sees a switch between the
    // internal and external sources. The external .vtt only drives HLS, where
    // the original file is no longer streamed.
    //
    // Except in a browser, which cannot see a file's embedded subtitle tracks at
    // all — a <video> knows only <track> elements. There the external WebVTT is
    // the only source there has ever been, Direct Play included.
    if (currentQuality == null && !_hlsOnly) {
      liveSubtitles.stop();
      _applyInternalSubtitleSelection();
      return;
    }

    final lang = _selectedSubtitleLang;
    final reqId = ++_subtitleRequestId;

    // Always clear the current external subtitle first. mpv's `sub-add ... select`
    // does NOT reliably switch the active selection when another external track
    // is already loaded (the second language would never show). Going through
    // `no()` first forces a clean re-selection. This also handles "off".
    if (AppPlatform.isWeb) {
      WebPlayback.clearSubtitles();
    } else {
      try {
        session.setSubtitles(const SubtitleSelection.none());
        debugPrint("SUB: cleared current subtitle before applying selection");
      } catch (_) {
        // Rien à effacer sur un moteur sans piste chargée.
      }
    }

    if (lang == null || lang.isEmpty) {
      _attachedSubtitleSignature = null;
      liveSubtitles.stop();
      return;
    }

    // A bitmap track is already painted into the video by the transcoder, so
    // there is no external file to attach — and mpv must stay on "no" or it
    // would render nothing on top of an already-subtitled picture.
    if (_trackForLang(lang)?.image ?? false) {
      _attachedSubtitleSignature = null;
      liveSubtitles.stop();
      return;
    }

    // Written by the session itself: follow it as it grows. Its clock is the
    // session's, which is also the engine's, so nothing needs shifting.
    final live =
        liveSourceFor(_hlsLiveSubtitles ?? const [], _trackForLang(lang));
    if (live != null) {
      _attachedSubtitleSignature = null;
      liveSubtitles.follow(live.url, positions: session.positions);
      return;
    }
    liveSubtitles.stop();
    _attachedSubtitleSignature = _subtitleSignature(lang);

    String? title;
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    for (final s in subs) {
      if (s.lang == lang) {
        title = s.displayName;
        break;
      }
    }

    // Download the WebVTT ourselves and inject it as in-memory data. Asking mpv
    // to fetch a URL works in Direct Play but is unreliable while it is pulling
    // an HLS stream — the external track silently never loads. The network round
    // trip also gives mpv time to process the `no()` above before we re-add.
    final inHls = currentQuality != null;
    final start = inHls ? _hlsStartOffset : 0;
    final mediaId = _media!.id;

    debugPrint("SUB: request #$reqId lang=$lang start=$start hls=$inHls");
    _loadSubtitleVtt(mediaId, lang, start).then((vtt) async {
      // Ignore stale responses (selection changed while we were fetching).
      if (_disposed || reqId != _subtitleRequestId) {
        debugPrint(
            "SUB: #$reqId stale (current=$_subtitleRequestId), skipping");
        return;
      }
      final cueCount = '-->'.allMatches(vtt).length;
      if (cueCount == 0) {
        debugPrint(
            "SUB: #$reqId lang=$lang has NO cues (${vtt.length} chars) — nothing to show");
        return;
      }
      debugPrint(
          "SUB: #$reqId lang=$lang fetched ${vtt.length} chars, $cueCount cues");
      try {
        if (AppPlatform.isWeb) {
          // Never media_kit's setSubtitleTrack here: it installs an oncuechange
          // handler that throws on every cue and prints a stack trace with it,
          // which starves the main thread and freezes the picture while the
          // sound carries on. Handing the cues to the browser also keeps them
          // visible in native full screen.
          WebPlayback.showSubtitleVtt(vtt, language: lang, label: title);
          debugPrint(
              "SUB: #$reqId applied via browser text track (lang=$lang)");
          return;
        }
        await session.setSubtitles(
          SubtitleSelection.vtt(vtt, title: title, language: lang),
        );
        // Read state only AFTER the command has actually run, plus a tick for
        // mpv's track-list event to propagate back.
        await Future.delayed(const Duration(milliseconds: 250));
        if (_disposed) return;
        final subs = session.subtitleTracks.map((t) => t.id).toList();
        debugPrint("SUB: #$reqId applied. engine subtitle tracks: $subs, "
            "active=${session.currentSubtitleTrack?.id}");
      } catch (e) {
        debugPrint(
            "SUB: #$reqId failed to attach data: ${redactPlaybackDiagnostic(e)}");
      }
    }).catchError((e) {
      debugPrint(
          "SUB: #$reqId failed to fetch lang=$lang: ${redactPlaybackDiagnostic(e)}");
    });
  }

  /// Direct Play: re-select the embedded subtitle that matches the user's choice
  /// after a reload (e.g. returning from HLS). Tries the exact mpv id first, then
  /// language matching, so the same subtitle stays on without a visible flip.
  void _applyInternalSubtitleSelection() {
    if (_subtitlesExplicitlyOff) {
      try {
        session.setSubtitles(const SubtitleSelection.none());
      } catch (_) {
        // Déjà sans sous-titres sur un moteur qui n'a rien chargé.
      }
      return;
    }

    if (_selectedInternalSubId == null && _selectedSubtitleLang == null) {
      try {
        session.setSubtitles(const SubtitleSelection.none());
      } catch (_) {
        // Déjà sans sous-titres sur un moteur qui n'a rien chargé.
      }
      return;
    }

    final tracks = session.subtitleTracks;
    if (tracks.isEmpty) return;

    PlaybackTrack? match;
    if (_selectedInternalSubId != null) {
      for (final t in tracks) {
        if (t.id == _selectedInternalSubId) {
          match = t;
          break;
        }
      }
    }
    if (match == null && _selectedSubtitleLang != null) {
      match = _embeddedSubtitles.trackFor(_selectedSubtitleLang!);
    }
    try {
      session.setSubtitles(
        match == null
            ? const SubtitleSelection.none()
            : SubtitleSelection.track(match),
      );
    } catch (_) {
      // Piste refusée par le moteur : l'image continue sans sous-titres.
    }
  }

  /// Canonical language key of an embedded subtitle track, read from the
  /// server's list instead of derived here.
  ///
  /// This used to be a local mapping table, which is what broke the Direct Play
  /// → HLS carry-over: it disagreed with the server's for `pol` (po vs pl),
  /// `tur` (tu vs tr), `swe` (sw vs sv), `ces`/`cze` (ce/cz vs cs), and it
  /// truncated every 3-letter code the server left untouched (`heb` → `he`).
  /// Picking a subtitle in Direct Play then switching to HLS silently lost it.
  /// There is now exactly one place where a language code is decided: the server.
  String? _canonicalLangForEmbedded(PlaybackTrack? track) =>
      track == null ? null : _embeddedSubtitles.keyOf(track);

  /// Which engine track is which server entry. See [EmbeddedSubtitlePairing].
  EmbeddedSubtitlePairing get _embeddedSubtitles => EmbeddedSubtitlePairing.of(
        session.subtitleTracks,
        mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[],
      );

  /// Re-apply audio + subtitle selection once the freshly opened media has
  /// enumerated its tracks (with a safety fallback).
  void _reapplySelectionsAfterLoad() {
    _reapplySubscription?.cancel();
    var applied = false;

    void apply() {
      if (applied || _disposed) return;
      applied = true;
      _applyAudioSelection();
      _applySubtitleSelection();
      _reapplySubscription?.cancel();
      _reapplySubscription = null;
    }

    bool hasAudio() =>
        session.audioTracks.any((e) => e.id != 'auto' && e.id != 'no');

    _reapplySubscription = session.trackChanges.listen((_) {
      if (hasAudio()) apply();
    });
    Timer(const Duration(milliseconds: 1500), () {
      // En Direct Play le choix se pose sur les pistes du fichier : tant que
      // le moteur ne les a pas listées (démarrage lent, TV, réseau distant),
      // appliquer ne fait rien et brûlait la seule tentative. L'écoute
      // ci-dessus reste alors en place pour le moment où elles arrivent.
      if (currentQuality == null && !_hlsOnly && !hasAudio()) return;
      apply();
    });
  }
}
