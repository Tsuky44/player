import AVFoundation
import AetherEngine
import CoreMedia

/// Fait démarrer un film dès que le premier segment est en mémoire.
///
/// AVPlayer ne lance la lecture qu'avec environ deux segments de 4 s d'avance
/// (`AVPlayerWaitingToMinimizeStallsReason`). Sur un remux 4K, c'est ~40 Mo
/// avant la première image en mouvement : mesuré 6,0 s de démarrage, dont
/// 2,2 s passées à attendre le second segment avec 3,5 s déjà en réserve.
/// mpv démarrait, lui, sur quelques Mo.
///
/// AetherEngine coupe court à cette attente pour le direct (`AE#440`,
/// `liveJoinStartsImmediately`), pas pour un film. On applique ici la même
/// règle, une seule fois par ouverture et avec les mêmes gardes :
/// `playImmediately` seulement sur un tampon non vide et assez profond. Sur un
/// tampon vide, AVPlayer le traite comme une panne et reste à l'arrêt ; c'est
/// l'échec qu'AetherEngine a mesuré en coupant l'attente pour de bon. Passé le
/// démarrage, un rechargement en cours de lecture garde la règle d'AVPlayer.
@MainActor
final class FastStart {
  /// Au-dessous d'un segment, le coussin est un fragment et la lecture
  /// repartirait en attente aussitôt. 2 s laisse une marge sur le 1,5 s
  /// d'AetherEngine, calibré pour un direct servi en temps réel : un fichier
  /// arrive en général plus vite que sa lecture, et la réserve grossit.
  static let minimumBufferAhead: Double = 2.0
  /// Un démarrage qui n'a pas eu lieu dans ce délai n'attend plus sa réserve :
  /// il est en panne, et ce n'est pas à ce raccourci de s'en mêler.
  private static let window: Duration = .seconds(20)
  private static let pollInterval: Duration = .milliseconds(150)

  private var task: Task<Void, Never>?

  /// À appeler à chaque ouverture. [wantsPlay] est relu à chaque tour : une
  /// pause demandée pendant le démarrage désarme le raccourci.
  func arm(engine: AetherEngine, wantsPlay: @escaping @MainActor () -> Bool) {
    cancel()
    // Le lecteur peut être réutilisé d'une ouverture à l'autre : l'élément en
    // cours avant celle-ci ne dit rien du démarrage qui vient.
    let previousItem = engine.currentAVPlayerItem
    task = Task { @MainActor in
      let deadline = ContinuousClock.now + Self.window
      while !Task.isCancelled, ContinuousClock.now < deadline {
        try? await Task.sleep(for: Self.pollInterval)
        guard let player = engine.currentAVPlayer,
              let item = player.currentItem,
              item !== previousItem
        else { continue }
        switch player.timeControlStatus {
        case .playing:
          return
        case .paused:
          continue
        case .waitingToPlayAtSpecifiedRate:
          guard wantsPlay(),
                player.reasonForWaitingToPlay == .toMinimizeStalls,
                !item.isPlaybackBufferEmpty
          else { continue }
          let ahead = Self.bufferedAhead(of: item)
          guard ahead >= Self.minimumBufferAhead else { continue }
          EngineLog.emit(
            "[Onyx] démarrage sans attendre le second segment (réserve "
              + String(format: "%.2f", ahead) + " s)")
          player.playImmediately(atRate: player.defaultRate > 0 ? player.defaultRate : 1)
          return
        @unknown default:
          return
        }
      }
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  /// Secondes contiguës en mémoire devant la position de lecture. Le premier
  /// segment commence souvent un peu après la position demandée (le moteur le
  /// cale sur l'image clé) : une plage qui démarre à moins d'une demi-seconde
  /// devant compte.
  static func bufferedAhead(of item: AVPlayerItem) -> Double {
    let now = item.currentTime()
    guard now.isValid, now.isNumeric else { return 0 }
    let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      guard range.start <= now + tolerance, range.end > now else { continue }
      let ahead = (range.end - now).seconds
      return ahead.isFinite ? ahead : 0
    }
    return 0
  }
}
