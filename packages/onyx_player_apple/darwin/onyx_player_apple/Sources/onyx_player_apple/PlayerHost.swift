import Foundation

/// Les lecteurs vivants, et le contrat Pigeon qui les pilote.
///
/// Pigeon appelle ces méthodes sur le thread principal, mais son protocole
/// n'est pas isolé sur `MainActor`, alors qu'AetherEngine l'est entièrement.
/// Chaque appel passe donc par `onMain`, qui le vérifie au lieu de le supposer :
/// un appel venu d'ailleurs s'arrête net plutôt que de courir sur le moteur.
final class PlayerHost: NSObject, OnyxApplePlayerApi {
  let statuses = StatusStream()
  let subtitles = SubtitleStream()
  let engineLog = EngineLogRelay()

  private var players: [Int64: AetherPlayer] = [:]
  private var nextId: Int64 = 1

  /// Le lecteur auquel une vue se rattache. Nil s'il a déjà été détruit : la
  /// vue reste noire plutôt que de faire tomber l'app.
  func player(_ id: Int64) -> AetherPlayer? {
    players[id]
  }

  private func onMain<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
    try MainActor.assumeIsolated(body)
  }

  private func require(_ id: Int64) throws -> AetherPlayer {
    guard let player = players[id] else {
      throw PigeonError(code: "unknown_player", message: "Lecteur \(id) inconnu ou détruit", details: nil)
    }
    return player
  }

  // MARK: - OnyxApplePlayerApi

  func create() throws -> Int64 {
    try onMain {
      let id = nextId
      nextId += 1
      let statuses = self.statuses
      let subtitles = self.subtitles
      players[id] = try AetherPlayer(
        id: id,
        onStatus: { statuses.send($0) },
        onSubtitles: { subtitles.send($0) })
      return id
    }
  }

  func release(playerId: Int64) throws {
    onMain { players.removeValue(forKey: playerId)?.release() }
  }

  func open(playerId: Int64, url: String, startPositionMs: Int64, play: Bool) throws {
    try onMain { try require(playerId).open(url, startMs: startPositionMs, play: play) }
  }

  func play(playerId: Int64) throws {
    try onMain { try require(playerId).play() }
  }

  func pause(playerId: Int64) throws {
    try onMain { try require(playerId).pause() }
  }

  func seekTo(playerId: Int64, positionMs: Int64) throws {
    try onMain { try require(playerId).seek(toMs: positionMs) }
  }

  func stop(playerId: Int64) throws {
    try onMain { try require(playerId).stop() }
  }

  func setVolume(playerId: Int64, volume: Double) throws {
    try onMain { try require(playerId).engine.volume = Float(volume) }
  }

  func setRate(playerId: Int64, rate: Double) throws {
    try onMain { try require(playerId).engine.setRate(Float(rate)) }
  }

  func setPreferredAudioLanguages(playerId: Int64, priorities: [String]) throws {
    try onMain { try require(playerId).preferredAudioLanguages = priorities }
  }

  func selectAudioTrack(playerId: Int64, trackId: String) throws {
    try onMain { try require(playerId).selectAudioTrack(trackId) }
  }

  func selectSubtitleTrack(playerId: Int64, trackId: String?) throws {
    try onMain { try require(playerId).selectSubtitleTrack(trackId) }
  }

  func setExternalSubtitle(playerId: Int64, vttContent: String?, language: String?, title: String?) throws {
    try onMain {
      try require(playerId).setExternalSubtitle(vttContent, language: language, title: title)
    }
  }

  func status(playerId: Int64) throws -> OnyxApplePlayerStatus {
    try onMain { try require(playerId).snapshot() }
  }

  func stats(playerId: Int64) throws -> OnyxApplePlaybackStats {
    try onMain { try require(playerId).stats() }
  }
}
