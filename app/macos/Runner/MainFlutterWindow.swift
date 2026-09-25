import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Cocoa remembers the size and position under this name, so relaunching
  /// reopens the window where the owner left it. Done natively rather than
  /// with a window plugin.
  private static let autosaveName = "DoomsadayMainWindow"

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // The sidebar layout needs room: below this the window would be forced
    // back into the phone breakpoint on a desktop.
    self.minSize = NSSize(width: 900, height: 600)
    self.contentMinSize = NSSize(width: 900, height: 600)

    self.setFrameAutosaveName(Self.autosaveName)
    if !self.setFrameUsingName(Self.autosaveName) {
      // First launch: open wide enough for the 1100 pt desktop layout.
      self.setContentSize(NSSize(width: 1280, height: 820))
      self.center()
    }

    // The app menu's "Settings…" talks to Flutter over this channel; the Dart
    // side listens on the same name in lib/app/mac_menu.dart.
    (NSApp.delegate as? AppDelegate)?.menuChannel = FlutterMethodChannel(
      name: "doomsaday/menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
