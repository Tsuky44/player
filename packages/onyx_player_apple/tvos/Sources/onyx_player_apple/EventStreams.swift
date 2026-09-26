import Foundation

/// Les puits des flux Pigeon. Un par flux : Pigeon génère une classe par
/// méthode `@EventChannelApi`, et ces classes ne partagent pas de type
/// générique qu'on pourrait sous-classer une seule fois.
///
/// Chaque puits n'est touché que depuis le thread principal : c'est là que
/// Flutter appelle `onListen`, et c'est là que les lecteurs émettent.

final class StatusStream: StatusChangedStreamHandler {
  private var sink: PigeonEventSink<OnyxApplePlayerStatus>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<OnyxApplePlayerStatus>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func send(_ status: OnyxApplePlayerStatus) {
    sink?.success(status)
  }
}

final class SubtitleStream: SubtitlesChangedStreamHandler {
  private var sink: PigeonEventSink<OnyxAppleSubtitleFrame>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<OnyxAppleSubtitleFrame>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func send(_ frame: OnyxAppleSubtitleFrame) {
    sink?.success(frame)
  }
}

/// Le journal d'AetherEngine, relayé vers Dart par paquets.
///
/// `EngineLog.handler` est appelé depuis n'importe quel thread, parfois des
/// dizaines de fois par seconde pendant une ouverture. Une ligne par message
/// de plateforme coûterait un saut de thread chacune : les lignes s'accumulent
/// sous verrou et partent au plus quatre fois par seconde, depuis le thread
/// principal.
final class EngineLogRelay: EngineLogStreamHandler {
  /// Sans écouteur, les lignes ne partent nulle part : on n'en garde que les
  /// dernières, pour que l'ouverture qui précède l'abonnement reste lisible.
  private static let backlogLimit = 500
  private static let flushDelay: TimeInterval = 0.25

  private let lock = NSLock()
  private var pending: [String] = []
  private var flushScheduled = false
  private var sink: PigeonEventSink<[String]>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<[String]>) {
    self.sink = sink
    flush()
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func append(_ line: String) {
    lock.lock()
    pending.append(line)
    if pending.count > Self.backlogLimit {
      pending.removeFirst(pending.count - Self.backlogLimit)
    }
    let schedule = !flushScheduled
    flushScheduled = true
    lock.unlock()

    if schedule {
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushDelay) { [weak self] in
        self?.flush()
      }
    }
  }

  private func flush() {
    guard let sink else {
      lock.lock()
      flushScheduled = false
      lock.unlock()
      return
    }
    lock.lock()
    let lines = pending
    pending.removeAll(keepingCapacity: true)
    flushScheduled = false
    lock.unlock()
    if !lines.isEmpty { sink.success(lines) }
  }
}
