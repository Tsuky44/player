import AetherEngine
import Combine
import CoreGraphics
import Foundation

/// Un lecteur : une instance d'AetherEngine, et ce qu'il faut pour la
/// raconter à Dart.
///
/// Toute la logique de lecture (reprise, sessions HLS, choix des pistes par
/// défaut) appartient au contrôleur de l'app. Ce type ne fait que traduire :
/// des commandes vers le moteur, des changements du moteur vers des
/// instantanés d'état.
@MainActor
final class AetherPlayer {
  let id: Int64
  let engine: AetherEngine

  /// Appliqué à la prochaine ouverture. Changer d'audio après coup reconstruit
  /// la session, ce qui se voit (image noire) et s'entend.
  var preferredAudioLanguages: [String] = []

  private let onStatus: (OnyxApplePlayerStatus) -> Void
  private let onSubtitles: (OnyxAppleSubtitleFrame) -> Void
  private var subscriptions = Set<AnyCancellable>()

  private var loadTask: Task<Void, Never>?

  /// Une ouverture qui a levé une erreur sans que le moteur passe en `.error`
  /// (une URL refusée avant toute session, par exemple). Sans elle, l'app
  /// attendrait la fin de son délai de démarrage sans savoir pourquoi.
  private var loadFailure: String?
  /// Le dernier play/pause demandé pendant un chargement. Le contrôleur ouvre
  /// en pause puis appelle play() tout de suite ; le moteur ignore un play
  /// arrivé avant la fin de `load`, et la lecture restait en pause.
  private var wantsPlay = false

  private var statusScheduled = false
  private var subtitlesScheduled = false
  private var activeCues = ActiveCues()

  /// Le WebVTT du serveur, écrit dans un fichier parce qu'AetherEngine ne prend
  /// des sous-titres externes que par URL.
  private var externalSubtitle: (trackId: Int, file: URL)?

  private var released = false

  init(
    id: Int64,
    onStatus: @escaping (OnyxApplePlayerStatus) -> Void,
    onSubtitles: @escaping (OnyxAppleSubtitleFrame) -> Void
  ) throws {
    self.id = id
    self.engine = try AetherEngine()
    self.onStatus = onStatus
    self.onSubtitles = onSubtitles
    observe()
  }

  // MARK: - Commandes

  func open(_ url: String, startMs: Int64, play: Bool) throws {
    guard let source = Self.sourceURL(url) else {
      throw PigeonError(code: "bad_url", message: "URL de lecture illisible", details: nil)
    }
    Self.registerSecrets(of: source)

    loadTask?.cancel()
    loadFailure = nil
    // Une ouverture vide le registre des pistes externes du moteur : le
    // fichier de l'ancienne ne sert plus à rien.
    forgetExternalSubtitle()
    clearSubtitleFrame()

    wantsPlay = play
    let options = LoadOptions(preferredAudioLanguages: preferredAudioLanguages, autoplay: play)
    let start: Double? = startMs > 0 ? Double(startMs) / 1000 : nil
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.engine.load(url: source, startPosition: start, options: options)
        guard !Task.isCancelled else { return }
        self.loadTask = nil
        if self.wantsPlay != play {
          if self.wantsPlay { self.engine.play() } else { self.engine.pause() }
        }
      } catch is CancellationError {
        // Une ouverture plus récente l'a remplacée : ce n'est pas une panne.
      } catch {
        guard !Task.isCancelled else { return }
        self.loadTask = nil
        self.loadFailure = error.localizedDescription
        self.scheduleStatus()
      }
    }
    scheduleStatus()
  }

  func play() {
    wantsPlay = true
    if loadTask == nil { engine.play() }
  }

  func pause() {
    wantsPlay = false
    if loadTask == nil { engine.pause() }
  }

  func seek(toMs positionMs: Int64) {
    let seconds = Double(max(positionMs, 0)) / 1000
    Task { await engine.seek(to: seconds) }
  }

  /// Décharge le média sans toucher au mode de l'écran : l'épisode suivant
  /// arrive souvent juste derrière, et un téléviseur qui repasse en SDR entre
  /// deux épisodes HDR, c'est deux écrans noirs de plus.
  func stop() {
    loadTask?.cancel()
    loadTask = nil
    loadFailure = nil
    forgetExternalSubtitle()
    engine.stop(resetDisplayCriteria: false, finalTeardown: false)
    clearSubtitleFrame()
    scheduleStatus()
  }

  /// La vraie fin : le mode de l'écran est rendu, l'audio aussi.
  func release() {
    released = true
    loadTask?.cancel()
    forgetExternalSubtitle()
    subscriptions.removeAll()
    engine.stop()
  }

  func selectAudioTrack(_ trackId: String) throws {
    let index = try Self.streamIndex(trackId)
    engine.selectAudioTrack(index: index)
  }

  func selectSubtitleTrack(_ trackId: String?) throws {
    guard let trackId else {
      engine.clearSubtitle()
      return
    }
    let index = try Self.streamIndex(trackId)
    engine.selectSubtitleTrack(index: index)
  }

  func setExternalSubtitle(_ vtt: String?, language: String?, title: String?) throws {
    forgetExternalSubtitle()
    guard let vtt else {
      engine.clearSubtitle()
      return
    }
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("onyx-subtitles-\(id)-\(UUID().uuidString).vtt")
    try vtt.write(to: file, atomically: true, encoding: .utf8)
    let track = engine.addExternalSubtitleTrack(
      ExternalSubtitleTrack(url: file, name: title, language: language, formatHint: "webvtt"))
    externalSubtitle = (track.id, file)
    engine.selectSubtitleTrack(index: track.id)
  }

  private func forgetExternalSubtitle() {
    guard let external = externalSubtitle else { return }
    externalSubtitle = nil
    engine.removeExternalSubtitleTrack(id: external.trackId)
    try? FileManager.default.removeItem(at: external.file)
  }

  // MARK: - État

  func snapshot() -> OnyxApplePlayerStatus {
    let phase = engine.playbackPhase
    let width = Int64(engine.sourceVideoWidth)
    let height = Int64(engine.sourceVideoHeight)
    let pixelAspect = engine.sourceVideoPixelAspectRatio

    var errorKind: OnyxApplePlayerErrorKind?
    var errorMessage: String?
    if case .error(let message) = phase {
      errorKind = engine.errorInfo.map { StatusMapping.errorKind($0.kind) } ?? .unknown
      errorMessage = engine.errorInfo?.message ?? message
    } else if let loadFailure {
      errorKind = engine.errorInfo.map { StatusMapping.errorKind($0.kind) } ?? .unknown
      errorMessage = loadFailure
    }

    return OnyxApplePlayerStatus(
      playerId: id,
      state: loadFailure != nil ? .idle : StatusMapping.state(phase),
      isPlaying: StatusMapping.isPlaying(phase),
      positionMs: StatusMapping.milliseconds(engine.clock.currentTime),
      durationMs: StatusMapping.milliseconds(engine.duration),
      bufferedPositionMs: StatusMapping.milliseconds(engine.clock.bufferedPosition),
      videoSize: width > 0 && height > 0 ? OnyxAppleVideoSize(width: width, height: height) : nil,
      pixelAspectRatio: pixelAspect.isFinite && pixelAspect > 0 && pixelAspect != 1 ? pixelAspect : nil,
      audioTracks: engine.audioTracks.map(StatusMapping.track),
      subtitleTracks: engine.subtitleTracks.map(StatusMapping.track),
      selectedAudioTrackId: engine.activeAudioTrackIndex.map { String($0) },
      selectedSubtitleTrackId: engine.activeSubtitleTrackIndex.map { String($0) },
      videoFormat: StatusMapping.videoFormat(engine.videoFormat),
      errorKind: errorKind,
      errorMessage: errorMessage)
  }

  func stats() -> OnyxApplePlaybackStats {
    let telemetry = engine.liveTelemetry
    return OnyxApplePlaybackStats(
      droppedFrames: telemetry?.droppedFrameCount.map { Int64($0) },
      observedFps: telemetry?.observedFps,
      containerFps: engine.sourceVideoFrameRate,
      videoCodec: engine.sourceVideoCodecName,
      videoDecoder: engine.activeVideoDecoder,
      audioDecoder: engine.activeAudioDecoder,
      videoBitrate: engine.sourceVideoBitrate > 0 ? engine.sourceVideoBitrate : nil,
      averageBitrateMbps: telemetry?.averageBitrateMbps,
      route: engine.videoRoute.rawValue,
      audioDelivery: engine.audioDelivery.rawValue,
      container: engine.sourceContainerFormat)
  }

  // MARK: - Observation

  /// Chaque changement du moteur demande un instantané ; les demandes d'un
  /// même tour de boucle n'en font partir qu'un.
  ///
  /// Les `@Published` émettent *avant* d'écrire la nouvelle valeur :
  /// l'instantané part donc au tour suivant, quand elle est en place. L'horloge
  /// tourne à 10 Hz ; quatre positions par seconde suffisent à la barre de
  /// lecture, comme sur Android.
  private func observe() {
    let tick = RunLoop.main
    let changes: [AnyPublisher<Void, Never>] = [
      Self.signal(engine.$playbackPhase),
      Self.signal(engine.$duration),
      Self.signal(engine.$audioTracks),
      Self.signal(engine.$subtitleTracks),
      Self.signal(engine.$activeAudioTrackIndex),
      Self.signal(engine.$activeSubtitleTrackIndex),
      Self.signal(engine.$errorInfo),
      Self.signal(engine.$sourceVideoWidth),
      Self.signal(engine.$sourceVideoHeight),
      Self.signal(engine.$videoFormat),
      Self.signal(engine.clock.$currentTime.throttle(for: .milliseconds(250), scheduler: tick, latest: true)),
      Self.signal(engine.clock.$bufferedPosition.throttle(for: .milliseconds(250), scheduler: tick, latest: true)),
    ]
    Publishers.MergeMany(changes)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleStatus() }
      }
      .store(in: &subscriptions)

    Publishers.Merge(Self.signal(engine.$subtitleCues), Self.signal(engine.clock.$sourceTime))
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleSubtitles() }
      }
      .store(in: &subscriptions)
  }

  private static func signal<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never>
  where P.Failure == Never {
    publisher.map { _ in () }.eraseToAnyPublisher()
  }

  private func scheduleStatus() {
    guard !statusScheduled, !released else { return }
    statusScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.statusScheduled = false
        guard !self.released else { return }
        self.onStatus(self.snapshot())
      }
    }
  }

  private func scheduleSubtitles() {
    guard !subtitlesScheduled, !released else { return }
    subtitlesScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.subtitlesScheduled = false
        guard !self.released else { return }
        self.emitSubtitles()
      }
    }
  }

  private func emitSubtitles() {
    guard let active = activeCues.update(engine.subtitleCues, at: engine.clock.sourceTime) else { return }
    let canvas = CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
    onSubtitles(SubtitleFrames.frame(playerId: id, cues: active, canvas: canvas))
  }

  /// Efface ce qui est à l'écran, une fois. Une réplique restée affichée par-
  /// dessus le film suivant est le genre de reste qu'on remarque tout de suite.
  private func clearSubtitleFrame() {
    guard !activeCues.ids.isEmpty else { return }
    activeCues.reset()
    onSubtitles(OnyxAppleSubtitleFrame(playerId: id, lines: [], bitmaps: []))
  }

  // MARK: - Sources

  /// Le fichier du serveur, une session HLS, ou un chemin local : l'app passe
  /// un fichier téléchargé comme un chemin nu, que mpv acceptait tel quel.
  static func sourceURL(_ value: String) -> URL? {
    if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
    guard let url = URL(string: value), url.scheme != nil else { return nil }
    return url
  }

  /// Le ticket de lecture voyage dans l'URL. AetherEngine journalise ses URL :
  /// sans ceci, le journal exporté par l'utilisateur le contiendrait en clair.
  static func registerSecrets(of url: URL) {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    for item in items where item.name == "ticket" {
      if let value = item.value { EngineLog.registerSecret(value) }
    }
  }

  static func streamIndex(_ trackId: String) throws -> Int {
    guard let index = Int(trackId) else {
      throw PigeonError(code: "bad_track", message: "Piste inconnue : \(trackId)", details: nil)
    }
    return index
  }
}
