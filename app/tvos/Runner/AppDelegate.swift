import AVFoundation
import Flutter
import UIKit

/// L'hôte de l'app sur l'Apple TV (ADR-0028).
///
/// Généré par `flutter-tvos create`, puis complété de ce que l'hôte iOS fait
/// déjà : la session audio d'un lecteur vidéo, et le canal `onyx/device` que
/// `TvMode`, `ClientIdentity` et la session AVPlayer interrogent.
@main
class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let flutterViewController = FlutterViewController(project: nil, nibName: nil, bundle: nil)
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = flutterViewController
    window.makeKeyAndVisible()
    self.window = window

    GeneratedPluginRegistrant.register(with: self)
    registerDeviceChannel(messenger: flutterViewController.binaryMessenger)
    configureAudioSession()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Le pendant tvOS du canal `onyx/device` d'Android et d'iOS.
  ///
  /// - `isTelevision` : toujours vrai ici.
  /// - `deviceName` : le nom que l'utilisateur a donné à son Apple TV, montré
  ///   sur le téléphone qui approuve l'appairage.
  /// - `appVersion` : `package_info_plus` n'a pas de portage tvOS compatible
  ///   avec la version épinglée, la version se lit donc ici.
  /// - `setKeepScreenOn` : l'économiseur d'écran ne sait pas qu'une texture
  ///   Flutter est un film ; la session AVPlayer le suspend pendant la lecture.
  private func registerDeviceChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "onyx/device", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isTelevision":
        result(true)
      case "deviceName":
        result(UIDevice.current.name)
      case "appVersion":
        result(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
      case "setKeepScreenOn":
        UIApplication.shared.isIdleTimerDisabled = (call.arguments as? Bool) ?? false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Même raison que sur iOS (ADR-0011 §3) : sans la catégorie `.playback`,
  /// le son d'un film suit les règles d'une app d'ambiance.
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
