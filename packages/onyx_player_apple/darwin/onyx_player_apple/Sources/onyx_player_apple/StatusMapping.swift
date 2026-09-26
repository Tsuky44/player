import AetherEngine
import Foundation

/// La traduction du vocabulaire d'AetherEngine vers celui du contrat.
///
/// Des fonctions pures, à part du lecteur : c'est ici que se décide ce que
/// l'app croit de la lecture, et rien de cela ne dépend d'un moteur vivant.
enum StatusMapping {
  static func state(_ phase: PlaybackPhase) -> OnyxApplePlaybackState {
    switch phase {
    case .idle, .error: return .idle
    // Un saut et une réserve vide se voient de la même façon à l'écran :
    // l'image attend. C'est aussi ce que dit ExoPlayer.
    case .loading, .seeking, .rebuffering, .stalled: return .buffering
    case .playing, .paused: return .ready
    case .ended: return .ended
    }
  }

  static func isPlaying(_ phase: PlaybackPhase) -> Bool {
    if case .playing = phase { return true }
    return false
  }

  /// Ce qui se rattrape par le transcodage du serveur, et ce qui ne se
  /// rattrape pas. Dans le doute, `unknown` : le contrôleur tente alors le
  /// repli, ce qui coûte moins qu'un écran d'échec à tort.
  static func errorKind(_ kind: PlaybackErrorKind) -> OnyxApplePlayerErrorKind {
    switch kind {
    case .sourceOpenFailed, .sourceRefused, .sourceCertificateRejected, .sourceRateLimited,
      .vodSourceFailed:
      return .source
    case .noPlayableTrackWithinBudget, .dolbyVisionRequiresHardware, .nativeItemFailed,
      .softwarePipelineFailed, .audioBridgeProducedNoOutput:
      return .unsupported
    default:
      return .unknown
    }
  }

  static func videoFormat(_ format: VideoFormat) -> String {
    switch format {
    case .sdr: return "sdr"
    case .hdr10: return "hdr10"
    case .hdr10Plus: return "hdr10plus"
    case .dolbyVision: return "dolbyvision"
    case .hlg: return "hlg"
    }
  }

  /// Les codecs de sous-titres qui arrivent en images plutôt qu'en texte.
  private static let bitmapSubtitleCodecs: Set<String> = [
    "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub",
  ]

  @MainActor
  static func track(_ info: TrackInfo) -> OnyxAppleTrack {
    // Lu hors de l'autoclosure de `&&`, qui n'hérite pas de l'isolement
    // `@MainActor` de la constante (erreur en Swift 6).
    let closedCaptionTrackID = AetherEngine.a53ClosedCaptionTrackID
    return OnyxAppleTrack(
      id: String(info.id),
      title: info.name.isEmpty ? nil : info.name,
      language: info.language,
      codec: info.codec,
      channels: Int64(info.channels),
      isDefault: info.isDefault,
      isForced: info.isForced,
      isAtmos: info.isAtmos,
      isBitmap: bitmapSubtitleCodecs.contains(info.codec),
      isContainerStream: !info.isExternal && info.id != closedCaptionTrackID)
  }

  /// Secondes du moteur → millisecondes du contrat. Une durée inconnue arrive
  /// parfois en NaN ou en infini : l'app ne sait lire que 0.
  static func milliseconds(_ seconds: Double) -> Int64 {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int64((seconds * 1000).rounded())
  }
}
