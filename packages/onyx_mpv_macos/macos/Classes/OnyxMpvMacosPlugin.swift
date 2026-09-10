import Cocoa
import FlutterMacOS

/// Le côté natif de `MpvHostView` : fabrique les vues où mpv dessine, et donne
/// leur adresse à Dart, qui la passe à mpv comme `wid`.
public class OnyxMpvMacosPlugin: NSObject, FlutterPlugin {
  static let viewType = "onyx_mpv_macos/surface"

  /// Les vues vivantes, par identifiant de vue Flutter.
  ///
  /// Retenues ici et non seulement par Flutter : quand le widget disparaît,
  /// Flutter lâche la vue aussitôt, alors que mpv peut encore y présenter une
  /// image. Elle ne part qu'au `release`, envoyé par Dart une fois mpv détaché.
  static var views: [Int64: MpvHostView] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "onyx_mpv_macos", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(OnyxMpvMacosPlugin(), channel: channel)
    registrar.register(MpvHostViewFactory(), withId: viewType)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let id = (call.arguments as? NSNumber)?.int64Value else {
      result(FlutterError(code: "bad_args", message: "identifiant de vue attendu", details: nil))
      return
    }
    switch call.method {
    case "viewHandle":
      guard let view = Self.views[id] else {
        result(nil)
        return
      }
      result(NSNumber(value: Int64(Int(bitPattern: Unmanaged.passUnretained(view).toOpaque()))))
    case "release":
      Self.views.removeValue(forKey: id)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

final class MpvHostViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let view = MpvHostView(frame: .zero)
    OnyxMpvMacosPlugin.views[viewId] = view
    return view
  }
}

/// Le parent de la vue que mpv crée. Noir tant que mpv n'y a rien présenté.
final class MpvHostView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    autoresizesSubviews = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Aucun clic ne s'arrête ici, ni dans la vue de mpv en dessous : ils
  /// appartiennent aux détecteurs que le lecteur pose par-dessus.
  override func hitTest(_ point: NSPoint) -> NSView? {
    return nil
  }
}
