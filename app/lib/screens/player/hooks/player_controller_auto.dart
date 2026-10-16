part of 'use_player_controller.dart';

/// Comment une attente de bascule préparée s'est terminée.
enum _HandoffWait {
  /// La lecture est arrivée à la seconde où la nouvelle session commence.
  reached,

  /// Quelqu'un a repris la main entre-temps : recherche, pause, autre choix.
  cancelled,

  /// La lecture s'est figée avant d'y arriver, ou la session n'était pas
  /// prête : il n'y a plus rien à préserver.
  late,
}

/// La qualité automatique vue du contrôleur (ADR-0056) : ce que
/// [AutoQualityPilot] lit de la lecture, la mesure de la ligne, et le
/// changement de source préparé — la nouvelle session s'ouvre pendant que
/// l'ancienne source continue de jouer, et le moteur n'en change qu'à la
/// seconde où elle commence.
extension PlayerControllerAuto on PlayerController {
  /// Si l'Auto tient la qualité de cette lecture.
  bool get isAutoQuality => _auto.enabled;

  /// Si l'Auto a de quoi travailler ici : un flux, et une échelle de débits
  /// annoncée par le serveur.
  bool get autoQualityAvailable =>
      !isLocalPlayback &&
      (mediaTracks?.qualities.any((tier) => tier.bitrateBps > 0) ?? false);

  /// « Auto », choisi dans le menu Qualité.
  void chooseAutoQuality() {
    _auto.enabled = true;
    _notifyTracksChanged();
  }

  /// Le lecteur vient de vider son tampon de lui-même, ou quelqu'un vient de
  /// reprendre la main : une bascule en préparation ne vaut plus.
  void _noteDisturbance() {
    _handoffEpoch++;
    _auto.noteDisturbance();
  }

  AutoQualityReading _autoReading() {
    final tracks = mediaTracks;
    final ladder = tracks?.qualities ?? const <QualityTier>[];
    final sourceBps = tracks?.sourceBitrateBps ?? 0;
    var buffered = Duration.zero;
    try {
      buffered = session.bufferedAhead;
    } catch (_) {
      // Moteur pas encore prêt : aucune avance à compter.
    }
    return AutoQualityReading(
      eligible: !_disposed &&
          !isLocalPlayback &&
          hasFirstFrame &&
          ladder.isNotEmpty &&
          !isSwitchingQuality &&
          !_hlsSwapInFlight &&
          !_handoffInFlight &&
          !isDraggingSlider,
      playing: isPlaying,
      buffered: buffered,
      remaining: duration - position,
      ladder: AutoLadder(
        tiers: ladder,
        currentKey: currentQuality,
        sourceHeight: tracks?.video?.height ?? 0,
        sourceBps: sourceBps,
        // Une session qui recopie l'image envoie le débit du fichier, quel que
        // soit celui de son barreau.
        currentBps: currentQuality != null && _hlsVideoMode == 'copy'
            ? sourceBps
            : 0,
        directAllowed: !_hlsOnly && !_directPlayRuledOut,
        ceilingKey: _autoCeilingKey,
        ceilingBps: _autoCeilingCopies ? sourceBps : 0,
        maxEncodeHeight: _auto.maxEncodeHeight,
      ),
      speed: playbackSpeed,
    );
  }

  Future<AutoLineMeasure?> _measureLine(int wantBps) async {
    final media = _media;
    final api = _apiClient;
    final access = _playbackAccess;
    if (media == null || api == null || access == null || _disposed) {
      return null;
    }
    // Ce que le moteur reçoit pendant la mesure : les deux se partagent la
    // ligne au même instant.
    var measuring = true;
    final inUse = () async {
      var sum = 0;
      var count = 0;
      while (measuring && !_disposed) {
        int? bps;
        try {
          bps = await session.receivingBps();
        } catch (_) {
          // Moteur fermé entre-temps : rien à compter.
          return null;
        }
        if (bps == null) return null;
        sum += bps;
        count++;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      return count == 0 ? null : sum ~/ count;
    }();
    final spare = await api
        .measureLineBps(media.id, access: access, wantBps: wantBps)
        .whenComplete(() => measuring = false);
    final using = await inUse;
    return spare == null ? null : (spareBps: spare, inUseBps: using);
  }

  /// Sonde la ligne et le serveur, au moment où le tampon fond.
  ///
  /// D'abord le serveur : si son encodeur n'a pas d'avance sur ce que le
  /// lecteur lui demande, c'est lui qu'on attend. Sinon la ligne, comptée sur
  /// ce que le moteur reçoit — il tire alors tout ce qu'elle porte.
  ///
  /// [sideMeasure] : le tampon fond sans être vide, et le moteur peut tenir un
  /// cache plein qui ne reçoit que ce qu'il lit. `cache-speed` de mpv rend
  /// alors le débit de la scène, pas celui de la ligne, et l'Auto quittait le
  /// Direct Play sur une ligne qui portait le fichier : la ligne se mesure à
  /// côté (ADR-0065).
  Future<AutoSounding> _autoSound({
    required bool passive,
    bool sideMeasure = false,
  }) async {
    final media = _media;
    final api = _apiClient;
    final access = _playbackAccess;
    if (media == null || api == null || access == null || _disposed) {
      return const AutoSounding();
    }

    final sessionId = _hlsSessionId;
    if (currentQuality != null &&
        sessionId != null &&
        _hlsVideoMode != 'copy') {
      final health =
          await api.hlsSessionHealth(media.id, sessionId, access: access);
      // Deux segments : en dessous, le lecteur demande ce qui n'existe pas
      // encore. Un encodeur qui suit en garde une trentaine de secondes.
      if (health != null && health.aheadSeconds < 4) {
        // Ce que le moteur reçoit est alors ce que l'encodeur produit, pas
        // ce que la ligne porte. Mesuré avec un encodeur à 0,6× : la ligne,
        // à 5 Mbit/s, « mesurée » à 1,5 puis 0,3, et une descente jusqu'en
        // bas de l'échelle.
        //
        // Une session à peine ouverte n'a pas encore eu le temps de prendre
        // de l'avance : rien ne l'accuse, mais rien ne se mesure non plus.
        if (passive) return const AutoSounding();
        debugPrint('Auto: encodeur à ${health.aheadSeconds}s d’avance, '
            '${health.speed.toStringAsFixed(1)}× la vitesse de lecture');
        return const AutoSounding(encoderBehind: true);
      }
    }

    if (!sideMeasure) {
      final received = await _receivingBps();
      if (received != null) return AutoSounding(lineBps: received);
    }
    if (passive) return const AutoSounding();

    // Le moteur ne dit pas ce qu'il reçoit : tirer un morceau du fichier à
    // côté. La ligne se partage alors entre la mesure et la lecture, dont la
    // part se déduit de la pente du tampon quand elle est connue ; sinon la
    // mesure seule, qui pèche par défaut — un barreau trop bas se rattrape
    // en une remontée, un barreau trop haut en une coupure.
    final ladder = _autoReading().ladder;
    final wanted = ladder.sendingBps > 0 ? ladder.sendingBps : ladder.sourceBps;
    final measure = await _measureLine(wanted > 0 ? wanted : 8000000);
    if (measure == null) return const AutoSounding();
    final ratio = _auto.measuredRatio;
    final inUse = measure.inUseBps ??
        (ratio == null ? 0 : (ratio * ladder.sendingBps).round());
    return AutoSounding(lineBps: measure.spareBps + inUse);
  }

  /// Ce que le moteur reçoit, moyenné sur une seconde et demie ; null s'il
  /// ne le publie pas.
  ///
  /// Le premier relevé attend : le moteur compte sur la seconde écoulée, et
  /// juste après une recherche elle ne contient encore rien.
  Future<int?> _receivingBps() async {
    var sum = 0;
    var count = 0;
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_disposed) return null;
      int? bps;
      try {
        bps = await session.receivingBps();
      } catch (_) {
        // Moteur fermé entre-temps : rien à mesurer.
        return null;
      }
      if (bps == null) return null;
      sum += bps;
      count++;
    }
    final mean = sum ~/ count;
    // Un moteur qui ne reçoit rien ne mesure pas une ligne : il attend
    // autre chose.
    return mean < 64000 ? null : mean;
  }

  /// Exécute une décision de l'Auto. Rend vrai quand la lecture est bien
  /// passée à [target].
  ///
  /// [urgent] : l'image est déjà figée, il n'y a plus d'avance à préserver.
  Future<bool> _autoMove(AutoTarget target, {required bool urgent}) async {
    if (_disposed || _media == null || _apiClient == null) return false;
    if (isSwitchingQuality || _hlsSwapInFlight || _handoffInFlight) {
      return false;
    }
    final tier = target.tier;
    final bool moved;
    if (tier == null) {
      await switchToDirectPlay(quiet: true);
      moved = currentQuality == null;
    } else {
      final lead = urgent ? 0 : _handoffLeadSeconds();
      if (lead == 0) {
        // Trop peu d'avance pour préparer quoi que ce soit : la lecture se
        // fige de toute façon, autant ouvrir tout de suite.
        await switchToQuality(tier.key);
        moved = currentQuality == tier.key;
      } else {
        moved = await _handOff(tier.key, lead);
      }
    }
    // Le menu Qualité dit ce que l'Auto joue.
    if (moved && !_disposed) _notifyTracksChanged();
    return moved;
  }

  /// De combien de secondes la nouvelle session peut commencer en avant de la
  /// lecture, ou 0 quand l'avance en mémoire ne laisse pas le temps de la
  /// préparer.
  ///
  /// Tout ce temps sert à télécharger le début de la nouvelle session, à côté
  /// de l'ancienne source qui continue de recevoir : plus il est long, moins
  /// le changement se voit. Sur une ligne qui ne livre qu'une part de ce qui
  /// est lu, l'avance tient plus longtemps que sa durée — onze secondes en
  /// tiennent une vingtaine quand la ligne en livre la moitié. Mesuré : neuf secondes de préparation laissaient 2 s en
  /// mémoire et jusqu'à 1,4 s d'image figée sur un barreau à 3,5 Mbit/s.
  int _handoffLeadSeconds() {
    var ahead = 0;
    try {
      ahead = session.bufferedAhead.inSeconds;
    } catch (_) {
      // Moteur fermé entre-temps : pas d'avance connue.
    }
    if (ahead < 6) return 0;
    final ratio = _auto.measuredRatio;
    if (ratio == null || ratio >= AutoQuality.starvingRatio) {
      // La ligne suit (c'est une remontée), ou rien ne dit ce qu'elle
      // porte : s'en tenir à ce qui est sûrement en mémoire.
      return (ahead - 2).clamp(4, 10);
    }
    // La mesure se trompe de quinze points dans les deux sens sur huit
    // secondes, et le début de la nouvelle session prend sa part de la ligne
    // à l'ancienne source : la ligne est comptée un peu plus lente qu'elle ne
    // paraît, et un quart de ce que l'avance tiendrait reste en réserve.
    final lasts = ahead / (1 - ratio * 0.8);
    return (lasts * 0.75).floor().clamp(4, 20);
  }

  /// Prépare une session à [quality] qui commence [leadSeconds] plus loin,
  /// laisse la source en cours jouer jusque-là, puis change de source.
  ///
  /// Rien ne se voit avant le changement : ni sablier, ni position qui saute.
  /// Si quelqu'un reprend la main entre-temps, la session préparée est
  /// détruite et la lecture reste où elle est.
  Future<bool> _handOff(String quality, int leadSeconds) async {
    final media = _media;
    final api = _apiClient;
    final access = _playbackAccess;
    if (media == null || api == null || access == null) return false;

    final target = position.inSeconds + leadSeconds;
    // Trop près de la fin pour que le changement vaille son prix.
    if (duration.inSeconds > 0 && target > duration.inSeconds - 30) {
      return false;
    }
    final fromHls = currentQuality != null;
    // Comme [switchToQuality] : en quittant le Direct Play, un sous-titre
    // image ne survit que peint dans la vidéo.
    final burn = fromHls
        ? _hlsBurnedSubTypedIndex
        : (_subtitlesExplicitlyOff ? -1 : _burnIndexFor(_selectedSubtitleLang));

    _handoffInFlight = true;
    final epoch = _handoffEpoch;
    HlsSession? prepared;
    HlsPreload? preload;
    var handedOver = false;
    try {
      prepared = await api.startHlsSession(
        media.id,
        quality,
        startSeconds: target,
        audioIndex: _selectedAudioIndex,
        burnSubtitleIndex: burn,
        access: access,
        standby: true,
      );
      _preparedSessionId = prepared.sessionId;
      if (_disposed) return false;

      // Le temps que la lecture arrive à cette seconde sert à télécharger le
      // début de la session : le moteur le trouvera en mémoire.
      var ready = false;
      preload = await HlsPreload.open(prepared.masterUrl);
      final warming = Duration(seconds: leadSeconds + 4);
      if (preload != null) {
        unawaited(preload.warm(budget: warming));
      } else {
        unawaited(api
            .awaitHlsReady(prepared.masterUrl, budget: warming)
            .then((value) => ready = value));
      }
      var outcome = await _waitForHandoffPoint(
        target,
        epoch,
        budget: Duration(seconds: leadSeconds + 6),
      );
      if (_disposed) return false;
      // Un segment au moins : de quoi afficher sans attendre le serveur.
      if (preload != null) ready = preload.readySeconds >= 2;
      if (outcome == _HandoffWait.reached && !ready) {
        outcome = _HandoffWait.late;
      }
      // Un serveur qui ne connaît pas l'attente a déjà condamné la session
      // en cours : y rester, ce serait la voir disparaître sous la lecture.
      if (outcome == _HandoffWait.cancelled && fromHls && !prepared.standby) {
        outcome = _HandoffWait.late;
      }

      switch (outcome) {
        case _HandoffWait.cancelled:
          debugPrint('Auto: bascule vers $quality abandonnée');
          return false;
        case _HandoffWait.late:
          debugPrint('Auto: bascule vers $quality trop tardive — '
              'ouverture directe');
          await api.destroyHlsSession(media.id, prepared.sessionId,
              access: access);
          _preparedSessionId = null;
          prepared = null;
          if (!_auto.enabled) return false;
          await switchToQuality(quality);
          return currentQuality == quality;
        case _HandoffWait.reached:
          debugPrint('Auto: bascule vers $quality à ${target}s'
              '${preload == null ? '' : ' — ${preload.readySeconds.toStringAsFixed(1)} s déjà en mémoire'}');
          handedOver = true;
          final relay = preload;
          preload = null;
          await _openHlsSession(
            quality: quality,
            startSeconds: target,
            prepared: prepared,
            preload: relay,
            quiet: true,
          );
          return currentQuality == quality;
      }
    } catch (e) {
      debugPrint('Auto: bascule vers $quality impossible : '
          '${redactPlaybackDiagnostic(e)}');
      return false;
    } finally {
      _handoffInFlight = false;
      _preparedSessionId = null;
      preload?.close();
      // Une session préparée que personne ne lira occupe un encodeur du
      // serveur : elle est rendue tout de suite, sans attendre qu'il s'en
      // aperçoive.
      if (!handedOver && prepared != null) {
        unawaited(api.destroyHlsSession(media.id, prepared.sessionId,
            access: access));
      }
    }
  }

  /// Attend que la lecture atteigne [targetSeconds], sur la source en cours.
  Future<_HandoffWait> _waitForHandoffPoint(
    int targetSeconds,
    int epoch, {
    required Duration budget,
  }) async {
    const step = Duration(milliseconds: 100);
    final clock = Stopwatch()..start();
    var stalled = Duration.zero;
    while (true) {
      if (_disposed || epoch != _handoffEpoch || !_auto.enabled) {
        return _HandoffWait.cancelled;
      }
      // Un peu avant la seconde visée : le moteur met ce temps à lâcher une
      // source, et la position ne tombe pas à la milliseconde.
      if (position.inMilliseconds >= targetSeconds * 1000 - 120) {
        return _HandoffWait.reached;
      }
      if (isBuffering) {
        stalled += step;
        if (stalled >= const Duration(milliseconds: 1500)) {
          return _HandoffWait.late;
        }
      } else {
        stalled = Duration.zero;
        // En pause : rien ne presse plus, et rien ne dit quand la lecture
        // reprendra.
        if (!isPlaying) return _HandoffWait.cancelled;
      }
      if (clock.elapsed > budget) return _HandoffWait.late;
      await Future<void>.delayed(step);
    }
  }
}
