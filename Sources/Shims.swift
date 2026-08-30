import AppKit
import GhosttyKit

// Vendored Ghostty sources cast window controllers and windows to the types
// below (their app-target classes). GhosttyTabs uses its own window shell, so
// those casts never match and the associated action paths become no-ops. The
// types only need to exist for compilation. Every member here mirrors a call
// site in Ghostty.App.swift (v1.3.1).

class BaseTerminalController: NSWindowController {
    var surfaceTree = SplitTree<Ghostty.SurfaceView>()
    var focusedSurface: Ghostty.SurfaceView?
    var titleOverride: String?
    var commandPaletteIsShowing = false
    var focusFollowsMouse = false
    func toggleBackgroundOpacity() {}
    func promptTabTitle() {}
    @IBAction func changeTabTitle(_ sender: Any) {}
}

class TerminalWindow: NSWindow {
    func isTabBar(_ childViewController: NSTitlebarAccessoryViewController) -> Bool { false }
}

/// Only referenced via `window as? HiddenTitlebarTerminalWindow` in
/// SurfaceScrollView's macOS 26.0 NSScrollPocket workaround; never matches here.
class HiddenTitlebarTerminalWindow: TerminalWindow {}

/// From TerminalRestorable.swift (not vendored - pulls in the app's terminal
/// controller tree). SurfaceView's Codable init only throws these.
enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
}
