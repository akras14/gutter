import AppKit
import GhosttyKit

/// Owns the main window: frame sizing, the split shell, the toolbar, and
/// fullscreen chrome. Every piece of "window" logic lives here; AppDelegate
/// only creates this and forwards actions to it.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    /// Default content size, clamped to the visible screen at launch.
    static let defaultContentSize = NSSize(width: 1750, height: 1120)
    static let sidebarWidth: CGFloat = 330

    var splitVC: MainSplitViewController!
    private let sessions: SessionManager
    private var savedToolbar: NSToolbar?
    private var topEdgeArea: NSTrackingArea?

    init(sessions: SessionManager) {
        let split = MainSplitViewController(sessions: sessions)
        self.sessions = sessions

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Gutter"

        super.init(window: window)

        self.splitVC = split
        window.delegate = self
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified

        window.contentViewController = split
        if let visible = NSScreen.main?.visibleFrame {
            let maxContent = window.contentRect(forFrameRect: visible)
            let content = NSRect(
                origin: .zero,
                size: NSSize(width: min(Self.defaultContentSize.width, maxContent.width),
                             height: min(Self.defaultContentSize.height, maxContent.height)))
            window.setFrame(window.frameRect(forContentRect: content), display: false)
        }
        let hasSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame Gutter Main Window") != nil
        window.setFrameAutosaveName("Gutter Main Window")
        if !hasSavedFrame {
            window.center()
        }
        let hasSavedSplit = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames Gutter Main Split") != nil
        split.splitView.autosaveName = "Gutter Main Split"
        if !hasSavedSplit {
            split.setSidebarWidth(Self.sidebarWidth)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Toolbar

    private static let sidebarID = NSToolbarItem.Identifier("sidebar")

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.sidebarID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Toggle Sidebar"
        item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")
        // The action lives on AppDelegate (menu and toolbar share one target).
        item.action = #selector(AppDelegate.toggleSidebar(_:))
        item.isBordered = true
        return item
    }
}

// Fullscreen chrome: the top bar (toolbar) is removed for the duration of
// native fullscreen and only slides back while the pointer is in the top strip
// of the screen. Exiting fullscreen always restores it.
extension MainWindowController {
    func windowDidBecomeKey(_ notification: Notification) {
        // A key window with no view holding focus (fresh launch, focus lost
        // during activation) would eat keystrokes: menu key equivalents never
        // fire without a key window, and ghostty bindings need the surface
        // focused. If nothing owns focus, hand it to the terminal surface.
        guard window?.firstResponder is NSWindow,
              let session = sessions.selected else { return }
        window?.makeFirstResponder(session.view)
    }
    private static let topEdgeHeight: CGFloat = 40

    func windowWillEnterFullScreen(_ notification: Notification) {
        // Drop it before the transition zooms so it never floats over the content.
        savedToolbar = window?.toolbar
        window?.toolbar = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        installTopEdgeTracking()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        removeTopEdgeTracking()
        window?.toolbar = savedToolbar
        savedToolbar = nil
    }

    override func mouseEntered(with event: NSEvent) {
        // Only our top-strip tracking area may reveal the bar. Subviews with
        // their own tracking areas (the terminal surface tracks the mouse
        // across its entire frame and forwards the event via super) bubble
        // these events up the responder chain to us; pass those along.
        guard event.trackingArea === topEdgeArea else {
            super.mouseEntered(with: event)
            return
        }
        guard let window, window.styleMask.contains(.fullScreen), window.toolbar == nil,
              let toolbar = savedToolbar else { return }
        window.toolbar = toolbar
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === topEdgeArea else {
            super.mouseExited(with: event)
            return
        }
        guard let window, window.styleMask.contains(.fullScreen), window.toolbar != nil else { return }
        window.toolbar = nil
    }

    private func installTopEdgeTracking() {
        guard let content = window?.contentView, topEdgeArea == nil else { return }
        let height = Self.topEdgeHeight
        let area = NSTrackingArea(
            rect: NSRect(x: 0, y: content.bounds.maxY - height, width: content.bounds.width, height: height),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil)
        content.addTrackingArea(area)
        topEdgeArea = area
    }

    private func removeTopEdgeTracking() {
        if let area = topEdgeArea {
            window?.contentView?.removeTrackingArea(area)
            topEdgeArea = nil
        }
    }
}
