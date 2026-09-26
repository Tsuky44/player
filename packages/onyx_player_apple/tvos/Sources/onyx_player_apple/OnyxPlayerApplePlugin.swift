import AetherEngine
import Foundation

#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

/// Point d'entrée du plugin : branche le contrat Pigeon, les trois flux
/// d'événements et la fabrique de vues.
///
/// Rien n'est retenu ici. Les fermetures de Pigeon gardent l'hôte en vie tant
/// que le moteur Flutter existe, et c'est l'hôte qui possède les lecteurs.
public final class OnyxPlayerApplePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif

    let host = PlayerHost()
    OnyxApplePlayerApiSetup.setUp(binaryMessenger: messenger, api: host)
    StatusChangedStreamHandler.register(with: messenger, streamHandler: host.statuses)
    SubtitlesChangedStreamHandler.register(with: messenger, streamHandler: host.subtitles)
    EngineLogStreamHandler.register(with: messenger, streamHandler: host.engineLog)

    // Global au processus, comme le journal d'AetherEngine lui-même : un seul
    // relais, quel que soit le nombre de lecteurs.
    let relay = host.engineLog
    EngineLog.handler = { line in relay.append(line) }

    registrar.register(PlayerSurfaceFactory(host: host), withId: PlayerSurfaceFactory.viewType)
  }
}
