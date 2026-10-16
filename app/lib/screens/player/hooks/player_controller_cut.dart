part of 'use_player_controller.dart';

/// La reprise après une coupure du serveur en pleine lecture. La décision et
/// l'attente sont dans [StreamCutRecovery] ; ici, seulement la réouverture.
extension PlayerControllerCut on PlayerController {
  StreamCutRecovery _newCutRecovery() => StreamCutRecovery(
        reopenAt: _reopenAfterCut,
        alive: () => !_disposed,
      );

  /// Vrai quand la fin ou la panne que le moteur annonce est une coupure du
  /// flux, dont la reprise est lancée : l'écran ne doit pas enchaîner.
  bool _absorbCut() {
    final cuts = _cuts;
    if (cuts == null) return false;
    if (cuts.isRecovering) return true;
    final known = duration > Duration.zero
        ? duration
        : Duration(seconds: _knownDurationSeconds);
    if (!cuts.isCut(
      position: position,
      duration: known,
      localFile: _localFilePath != null,
    )) {
      return false;
    }
    ClientLog.error('Player: fin annoncée à ${position.inSeconds}s sur '
        '${known.inSeconds}s — flux coupé, reprise à cette seconde');
    unawaited(cuts.recover(position.inSeconds));
    return true;
  }

  Future<bool> _reopenAfterCut(int seconds) async {
    final media = _media;
    final api = _apiClient;
    if (media == null || api == null || _disposed) return false;
    isSwitchingQuality = true;
    _onQualitySwitchingChanged?.call();
    // Un serveur redémarré a oublié ses tickets et ses sessions HLS : il en
    // faut un neuf. L'obtenir est aussi la preuve qu'il répond de nouveau —
    // la demande échoue tant qu'il est arrêté.
    final access = await api.openPlaybackAccess(media.id);
    if (_disposed) {
      await access.close();
      return false;
    }
    final previous = _playbackAccess;
    _playbackAccess = access;
    unawaited(previous?.close());

    if (currentQuality != null) {
      // La session est partie avec le serveur : rien à détruire.
      _hlsSessionId = null;
      await reloadHlsAtPosition(seconds);
      return _hlsSessionId != null;
    }

    _openedAtSeconds = seconds;
    await session.open(
      _directPlaySource(api, media.id),
      start: Duration(seconds: seconds),
      play: true,
    );
    if (_disposed) return true;
    position = Duration(seconds: seconds);
    _onPositionChanged?.call();
    _reapplySelectionsAfterLoad();
    isSwitchingQuality = false;
    _onQualitySwitchingChanged?.call();
    return true;
  }
}
