import Flutter
import UIKit

/// Le canal `onyx/background_downloads` côté iPhone : confie des tranches de
/// fichier à [BackgroundTransferSession] et dit où elles en sont.
public final class OnyxBackgroundDownloadsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "onyx/background_downloads", binaryMessenger: registrar.messenger())
    let instance = OnyxBackgroundDownloadsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    // La session est recréée dès le lancement : c'est elle qui reçoit les
    // tranches arrivées pendant que l'app était suspendue ou fermée.
    BackgroundTransferSession.shared.activate()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let session = BackgroundTransferSession.shared
    switch call.method {
    case "enqueue":
      guard let raw = args["url"] as? String, let url = URL(string: raw),
        let start = (args["start"] as? NSNumber)?.int64Value,
        let end = (args["end"] as? NSNumber)?.int64Value,
        let destination = args["destination"] as? String
      else {
        result(FlutterError(code: "bad-args", message: "enqueue", details: nil))
        return
      }
      session.enqueue(url: url, start: start, end: end, destination: destination)
      result(nil)
    case "snapshot":
      guard let prefix = args["prefix"] as? String else {
        result(FlutterError(code: "bad-args", message: "snapshot", details: nil))
        return
      }
      session.snapshot(prefix: prefix) { result($0) }
    case "cancel":
      guard let prefix = args["prefix"] as? String else {
        result(FlutterError(code: "bad-args", message: "cancel", details: nil))
        return
      }
      session.cancel(prefix: prefix) { result(nil) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// iOS relance l'app en arrière-plan quand des tranches ont fini : il attend
  /// qu'on lui rende la main une fois les événements de la session traités.
  public func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) -> Bool {
    guard identifier == BackgroundTransferSession.identifier else { return false }
    BackgroundTransferSession.shared.onEventsFinished(completionHandler)
    return true
  }
}
