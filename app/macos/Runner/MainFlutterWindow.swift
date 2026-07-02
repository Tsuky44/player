import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Frameless chrome: keep traffic lights, hide title bar strip.
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    isMovableByWindowBackground = true

    RegisterGeneratedPlugins(registry: flutterViewController)
    NowPlayingController.shared.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
