import Foundation

/// Une session URLSession d'arrière-plan : les octets arrivent dans un
/// processus du système, écran verrouillé et app suspendue.
///
/// Elle ne connaît que des tranches (`Range:`) et leurs destinations. Une
/// tranche finie est déplacée à sa destination si le serveur a bien servi la
/// plage demandée ; sinon la raison est retenue pour [snapshot]. Assembler le
/// fichier, compter et réessayer reste au Dart, qui le teste.
///
/// Des tranches plutôt qu'une tâche par fichier : une tâche coupée ne rend ses
/// octets que par `resumeData`, qui rejoue l'URL d'origine et son ticket de
/// lecture — révoqué ou expiré entre-temps. Une tranche finie, elle, est sur le
/// disque et y reste.
final class BackgroundTransferSession: NSObject, URLSessionDownloadDelegate {
  static let shared = BackgroundTransferSession()

  static let identifier = (Bundle.main.bundleIdentifier ?? "onyx") + ".offline-downloads"

  private let lock = NSLock()
  /// Destination (relative au conteneur) → raison du dernier échec.
  private var failures: [String: String] = [:]
  private var eventsFinished: (() -> Void)?
  private var session: URLSession!

  private override init() {
    super.init()
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    configuration.sessionSendsLaunchEvents = true
    // Une tâche créée app au premier plan part tout de suite, même sur
    // batterie. Créée en arrière-plan, iOS la traite de toute façon comme
    // discrétionnaire.
    configuration.isDiscretionary = false
    configuration.httpMaximumConnectionsPerHost = 4
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }

  /// Force la création de la session (et donc de son délégué).
  func activate() {}

  func enqueue(url: URL, start: Int64, end: Int64, destination: String) {
    var request = URLRequest(url: url)
    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
    let task = session.downloadTask(with: request)
    let key = Self.relative(destination)
    task.taskDescription = key
    lock.withLock { failures[key] = nil }
    task.resume()
  }

  func snapshot(prefix: String, completion: @escaping ([String: Any]) -> Void) {
    session.getAllTasks { tasks in
      var running: [String: Int64] = [:]
      for task in tasks where task.state == .running || task.state == .suspended {
        guard let key = task.taskDescription else { continue }
        let path = Self.absolute(key)
        if path.hasPrefix(prefix) { running[path] = task.countOfBytesReceived }
      }
      let failed: [String: String] = self.lock.withLock {
        var matching: [String: String] = [:]
        for (key, message) in self.failures {
          let path = Self.absolute(key)
          if path.hasPrefix(prefix) { matching[path] = message }
        }
        return matching
      }
      DispatchQueue.main.async { completion(["running": running, "failures": failed]) }
    }
  }

  func cancel(prefix: String, completion: @escaping () -> Void) {
    session.getAllTasks { tasks in
      for task in tasks {
        if let key = task.taskDescription, Self.absolute(key).hasPrefix(prefix) { task.cancel() }
      }
      self.lock.withLock {
        self.failures = self.failures.filter { !Self.absolute($0.key).hasPrefix(prefix) }
      }
      DispatchQueue.main.async(execute: completion)
    }
  }

  func onEventsFinished(_ handler: @escaping () -> Void) {
    lock.withLock { eventsFinished = handler }
  }

  // MARK: - URLSessionDownloadDelegate

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let key = downloadTask.taskDescription else { return }
    let response = downloadTask.response as? HTTPURLResponse
    let status = response?.statusCode ?? 0
    // Un 401 (ticket expiré ou révoqué) arrive lui aussi comme un
    // téléchargement réussi : son corps est le message d'erreur.
    guard status == 206 else {
      record(key, "HTTP \(status)")
      return
    }
    let requested = downloadTask.originalRequest?.value(forHTTPHeaderField: "Range") ?? ""
    let served = response?.value(forHTTPHeaderField: "Content-Range") ?? ""
    guard Self.sameStart(requested: requested, served: served) else {
      record(key, "Plage inattendue")
      return
    }
    let destination = URL(fileURLWithPath: Self.absolute(key))
    let files = FileManager.default
    // Plus de dossier : le média a été supprimé pendant le transfert.
    guard files.fileExists(atPath: destination.deletingLastPathComponent().path) else { return }
    do {
      if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
      // Le fichier temporaire disparaît au retour de cette méthode : il est
      // déplacé ici, pas plus tard.
      try files.moveItem(at: location, to: destination)
    } catch {
      record(key, error.localizedDescription)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error, let key = task.taskDescription else { return }
    if (error as NSError).code == NSURLErrorCancelled { return }
    record(key, error.localizedDescription)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let handler = lock.withLock { () -> (() -> Void)? in
      let pending = eventsFinished
      eventsFinished = nil
      return pending
    }
    DispatchQueue.main.async { handler?() }
  }

  private func record(_ key: String, _ message: String) {
    lock.withLock { failures[key] = message }
  }

  /// `bytes=100-199` demandé, `bytes 100-199/1000` servi : même début.
  static func sameStart(requested: String, served: String) -> Bool {
    guard let asked = requested.split(separator: "=").last?.split(separator: "-").first,
      let got = served.split(separator: " ").last?.split(separator: "-").first
    else { return false }
    return asked == got
  }

  /// Les destinations sont gardées relatives au conteneur de l'app : son
  /// chemin absolu change d'une installation à l'autre, et une tâche peut
  /// finir après.
  static func relative(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
  }

  static func absolute(_ key: String) -> String {
    key.hasPrefix("/") ? key : NSHomeDirectory() + "/" + key
  }
}
