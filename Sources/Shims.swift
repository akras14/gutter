import AppKit
import GhosttyKit

// Vendored Ghostty sources cast window controllers and windows to the types
// below (their app-target classes). Every member here mirrors a call site in
// Ghostty.App.swift (v1.3.1).
//
// `TerminalWindow` and the two below it are compile-only: Gutter's window is
// not one, so those casts never match and their action paths stay no-ops.
//
// `BaseTerminalController` is NOT compile-only. `MainWindowController`
// subclasses it, because the core refuses to perform goto_split, resize_split
// and toggle_split_zoom unless the key window's controller is one, and reads
// `surfaceTree` / `focusedSurface` off it to decide whether the keybind is
// performable at all. Adding a stub here is how you turn one of those paths on;
// leaving one empty is how you leave it off. Currently inert by choice:
// `focusFollowsMouse` (no config wiring), `titleOverride` (stored, ignored),
// `toggleBackgroundOpacity`, and `commandPaletteIsShowing`.

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
