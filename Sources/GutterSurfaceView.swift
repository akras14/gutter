import AppKit
import GhosttyKit

/// The terminal surface Gutter puts on screen.
///
/// It exists for one reason: the right-click menu is ghostty's own, built in
/// the vendored `SurfaceView.menu(for:)` for ghostty's window shell. Several of
/// its items drive an app structure Gutter doesn't have, so they fire an action
/// into a notification nothing observes and look broken. This trims those.
/// Everything left in that menu - copy, paste, reset, read-only, the terminal
/// title prompt - works here.
final class GutterSurfaceView: Ghostty.SurfaceView {
    /// Menu actions with no listener in Gutter:
    ///
    /// - The four splits post `ghosttyNewSplit`, which `GhosttyBridge` does not
    ///   observe. Splits are declined outright - see `DESIGN.md`.
    /// - The inspector posts `didControlInspector`; there is no inspector view.
    private static let unsupported: Set<Selector> = [
        #selector(splitRight(_:)),
        #selector(splitLeft(_:)),
        #selector(splitDown(_:)),
        #selector(splitUp(_:)),
        #selector(toggleTerminalInspector(_:)),
    ]

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }

        for item in menu.items {
            guard let action = item.action, Self.unsupported.contains(action) else { continue }
            menu.removeItem(item)
        }

        // "Change Tab Title..." targets ghostty's own terminal controller,
        // which Gutter only stubs (`Shims.swift`), so nothing in the responder
        // chain answers it and AppKit greys it out. Point it at the sidebar
        // rename that ⇧⌘R uses instead - same intent, live target.
        if let item = menu.items.first(where: { $0.action == #selector(BaseTerminalController.changeTabTitle(_:)) }) {
            item.action = #selector(AppDelegate.renameTab(_:))
            item.target = NSApp.delegate
        }

        compactSeparators(in: menu)
        return menu
    }

    /// Removing whole groups leaves their separators behind, doubled up or
    /// stranded at an edge.
    private func compactSeparators(in menu: NSMenu) {
        var previousWasSeparator = true  // a leading separator is stranded too
        for item in menu.items {
            guard item.isSeparatorItem else {
                previousWasSeparator = false
                continue
            }
            if previousWasSeparator {
                menu.removeItem(item)
            } else {
                previousWasSeparator = true
            }
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
