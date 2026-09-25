import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// The channel MainFlutterWindow builds once the engine exists, so the app
  /// menu can reach Flutter. Nil until then, which is only the first moments
  /// of launch and before any menu can be picked.
  var menuChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// The standard app-menu item "Settings…" (Cmd+,).
  ///
  /// MainMenu.xib wires the item to this selector on the first responder; the
  /// app delegate is in that chain, so AppKit enables the item — a menu item
  /// with no action at all is what greys it out — and picking it opens the
  /// same Preferences dialog as the cog in the sidebar footer.
  @IBAction func showSettings(_ sender: Any?) {
    menuChannel?.invokeMethod("openPreferences", arguments: nil)
  }
}
