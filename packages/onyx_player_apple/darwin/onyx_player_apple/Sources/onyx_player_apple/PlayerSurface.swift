import AetherEngine
import Foundation

#if os(macOS)
  import AppKit
  import FlutterMacOS
#else
  import Flutter
  import UIKit
#endif

/// La vue où AetherEngine pose son image : une vraie vue du système, pas une
/// texture Flutter.
///
/// C'est tout l'intérêt. Une texture Flutter est en 8 bits BGRA, donc sans
/// HDR, et chaque image y serait recopiée. Ici, la couche d'AVPlayer (ou celle
/// du décodage logiciel) est composée par le système sous l'interface, avec
/// le Dolby Vision et sans copie. Voir l'ADR-0035 pour le même choix avec
/// AVPlayer seul.
///
/// La vue se rattache au lecteur, elle ne le crée pas : Flutter peut la
/// reconstruire sans interrompre la lecture. Le moteur ne tient ses vues que
/// faiblement, et reprend la dernière liée quand celle-ci disparaît.
final class PlayerSurfaceView: PlatformBaseView {
  private let playerView = AetherPlayerView(frame: .zero)

  init(player: AetherPlayer?) {
    super.init(frame: .zero)
    #if os(macOS)
      wantsLayer = true
      layer?.backgroundColor = CGColor.black
      playerView.autoresizingMask = [.width, .height]
    #else
      backgroundColor = .black
      // Les gestes appartiennent aux détecteurs que le lecteur pose par-dessus.
      isUserInteractionEnabled = false
      playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    #endif
    playerView.frame = bounds
    addSubview(playerView)
    player?.engine.bind(view: playerView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) n'est pas pris en charge")
  }

  #if os(macOS)
    /// Aucun clic ne s'arrête ici : ils vont aux détecteurs du lecteur, posés
    /// par-dessus côté Flutter.
    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }
  #endif
}

#if os(macOS)
  final class PlayerSurfaceFactory: NSObject, FlutterPlatformViewFactory {
    /// Doit correspondre au `viewType` du widget Dart.
    static let viewType = "onyx_player_apple/surface"
    static let playerIdKey = "playerId"

    private let host: PlayerHost

    init(host: PlayerHost) {
      self.host = host
    }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
      let player = Self.playerId(args).flatMap(host.player)
      return MainActor.assumeIsolated { PlayerSurfaceView(player: player) }
    }

    func createArgsCodec() -> (NSObjectProtocol & FlutterMessageCodec)? {
      FlutterStandardMessageCodec.sharedInstance()
    }

    static func playerId(_ args: Any?) -> Int64? {
      ((args as? [String: Any])?[playerIdKey] as? NSNumber)?.int64Value
    }
  }
#else
  final class PlayerSurface: NSObject, FlutterPlatformView {
    private let surface: PlayerSurfaceView

    init(surface: PlayerSurfaceView) {
      self.surface = surface
    }

    func view() -> UIView {
      surface
    }
  }

  final class PlayerSurfaceFactory: NSObject, FlutterPlatformViewFactory {
    /// Doit correspondre au `viewType` du widget Dart.
    static let viewType = "onyx_player_apple/surface"
    static let playerIdKey = "playerId"

    private let host: PlayerHost

    init(host: PlayerHost) {
      self.host = host
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
      -> FlutterPlatformView
    {
      let player = Self.playerId(args).flatMap(host.player)
      let surface = MainActor.assumeIsolated { PlayerSurfaceView(player: player) }
      return PlayerSurface(surface: surface)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
      FlutterStandardMessageCodec.sharedInstance()
    }

    static func playerId(_ args: Any?) -> Int64? {
      ((args as? [String: Any])?[playerIdKey] as? NSNumber)?.int64Value
    }
  }
#endif
