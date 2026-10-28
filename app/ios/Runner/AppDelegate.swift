import AVFoundation
import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureAudioSession()
    configureNewEpisodeAlerts()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OnyxDevice") {
      registerDeviceChannel(messenger: registrar.messenger())
    }
  }

  /// Ce qu'il faut à la veille des nouveaux épisodes (ADR-0059) pour tourner
  /// app fermée.
  ///
  /// Tout se fait ici, avant le retour de `didFinishLaunching` : iOS ne remet
  /// une tâche de fond à une app relancée que si son identifiant a été
  /// enregistré à ce moment-là, et avec les scènes Flutter n'inscrit ses
  /// plugins qu'après. L'identifiant est celui de `NewEpisodeAlerts.taskName`
  /// côté Dart et de `BGTaskSchedulerPermittedIdentifiers` dans l'Info.plist.
  private func configureNewEpisodeAlerts() {
    // Sans délégué, une notification touchée ouvre l'app sans dire laquelle,
    // et aucune ne s'affiche quand l'app est au premier plan.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    // Le moteur de la tâche de fond n'a aucun plugin tant qu'on ne les lui
    // inscrit pas : ni préférences pour lire le carnet de serveurs, ni
    // notifications à afficher.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.tsuky.onyx.new-episodes",
      earliestBeginInSeconds: NSNumber(value: 15 * 60)
    )
    WorkmanagerPlugin.registerLaunchHandlers()
  }

  /// Le pendant iOS du canal `onyx/device` d'Android, réduit à ce que
  /// `TvMode` lit au démarrage.
  ///
  /// `isTelevision` n'est vrai que sur une Apple TV (idiome `.tv`) : un iPhone
  /// branché sur un téléviseur passe en mode télécommande par le réglage, pas
  /// par la détection. `memoryProfile` dit la mémoire et le modèle, pour que
  /// `DeviceHardware` reconnaisse un vieil iPhone et passe en mode léger. Le
  /// reste du canal Android (fréquence d'écran, réseau facturé, image dans
  /// l'image) n'est pas appelé sur iOS.
  private func registerDeviceChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "onyx/device", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isTelevision":
        result(UIDevice.current.userInterfaceIdiom == .tv)
      case "deviceName":
        result(UIDevice.current.name)
      case "memoryProfile":
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw in
          String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        result([
          "totalMemoryMb": Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)),
          "isLowRamDevice": false,
          "model": model,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Déclare à iOS que cette app lit des médias.
  ///
  /// media_kit ne touche pas à `AVAudioSession` : sans cet appel, l'app reste
  /// dans la catégorie par défaut (`soloAmbient`), où le bouton silencieux de
  /// l'iPhone coupe le son du film et où la lecture s'arrête dès que l'écran
  /// se verrouille. C'est le premier symptôme qu'un testeur remonte, et il ne
  /// ressemble pas à un problème de configuration — il ressemble à un lecteur
  /// cassé.
  ///
  /// `.playback` est la catégorie des lecteurs vidéo : elle ignore le bouton
  /// silencieux et survit à l'écran verrouillé, ce que `UIBackgroundModes:
  /// audio` dans l'Info.plist autorise. Une erreur ici n'est pas fatale — le
  /// son sortira quand même, dans la catégorie par défaut.
  private func configureAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      NSLog("Onyx: configuration AVAudioSession impossible : \(error)")
    }
  }
}
