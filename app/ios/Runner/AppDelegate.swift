import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureAudioSession()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OnyxDevice") {
      registerDeviceChannel(messenger: registrar.messenger())
    }
  }

  /// Le pendant iOS du canal `onyx/device` d'Android, réduit à ce que
  /// `TvMode` lit au démarrage.
  ///
  /// `isTelevision` n'est vrai que sur une Apple TV (idiome `.tv`) : un iPhone
  /// branché sur un téléviseur passe en mode télécommande par le réglage, pas
  /// par la détection. Le reste du canal Android (mémoire, fréquence d'écran,
  /// réseau facturé, image dans l'image) n'est pas appelé sur iOS.
  private func registerDeviceChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "onyx/device", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isTelevision":
        result(UIDevice.current.userInterfaceIdiom == .tv)
      case "deviceName":
        result(UIDevice.current.name)
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
