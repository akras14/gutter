import AppKit
import GhosttyKit

/// Owns the main window: frame sizing, the split shell, the toolbar, and
/// fullscreen chrome. Every piece of "window" logic lives here; AppDelegate
/// only creates this and forwards actions to it.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    /// Default content size, clamped to the visible screen at launch.
    static let defaultContentSize = NSSize(width: 1750, height: 1120)
    static let sidebarWidth: CGFloat = 330

    private let splitVC: MainSplitViewController
    private let sessions: SessionManager
    private var savedToolbar: NSToolbar?
    private var pointerMonitor: Any?
    private var diffWindow: GitDiffWindowController?
    private var savedAcceptsMouseMoved: Bool?

    init(sessions: SessionManager) {
        let split = MainSplitViewController(sessions: sessions)
        self.splitVC = split
        self.sessions = sessions

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Gutter"

        super.init(window: window)

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

        // The window owns session -> UI wiring: sidebar refresh, showing the
        // selected surface, and handing it first responder.
        sessions.onListChanged = { [weak self] in
            self?.splitVC.sidebarReload()
        }
        sessions.onSelectionChanged = { [weak self] session in
            guard let self else { return }
            self.splitVC.show(session)
            self.window?.makeFirstResponder(session?.view)
        }
        // Last tab gone: close the window. applicationShouldTerminateAfter-
        // LastWindowClosed then quits the app. close(), not performClose():
        // the latter consults the delegate and can be vetoed.
        sessions.onEmpty = { [weak self] in
            self?.window?.close()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func beginRenameSelectedTab() {
        splitVC.beginRenameSelectedTab()
    }

    // MARK: Toolbar

    private static let sidebarID = NSToolbarItem.Identifier("sidebar")
    private static let gitDiffID = NSToolbarItem.Identifier("gitDiff")

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarID, .flexibleSpace, Self.gitDiffID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarID, .flexibleSpace, Self.gitDiffID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.sidebarID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Toggle Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")
            // Nil target: the responder chain delivers this to MainSplitViewController.
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            item.isBordered = true
            return item
        case Self.gitDiffID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Git Diff"
            item.toolTip = "Show uncommitted changes in this session's directory"
            item.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Git Diff")
            item.target = self
            item.action = #selector(showGitDiff(_:))
            item.isBordered = true
            return item
        default:
            return nil
        }
    }

    /// The diff is of whatever directory the selected session is sitting in
    /// (`pwd` comes from the shell, so it tracks `cd` inside the tab). One
    /// window, reused: clicking again refreshes it.
    @objc func showGitDiff(_ sender: Any?) {
        let controller = diffWindow ?? GitDiffWindowController()
        diffWindow = controller
        controller.present(directory: sessions.selected?.view.pwd)
    }
}

// Fullscreen chrome: the top bar (toolbar) is removed for the duration of
// native fullscreen and only slides back while the pointer is at the top edge
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

    /// Show the bar once the pointer is this close to the top of the screen.
    private static let revealEdge: CGFloat = 6
    /// Hide it again only once the pointer is this far below the revealed bar.
    /// The gap between the two is deliberate: showing the bar shrinks the
    /// content view, and without hysteresis the pointer would fall back out of
    /// the reveal zone the instant the bar appeared, flickering forever.
    private static let hideSlack: CGFloat = 8

    func windowWillEnterFullScreen(_ notification: Notification) {
        // Drop it before the transition zooms so it never floats over the content.
        savedToolbar = window?.toolbar
        window?.toolbar = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        startPointerTracking()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        stopPointerTracking()
        window?.toolbar = savedToolbar
        savedToolbar = nil
    }

    // The reveal zone is measured in *screen* coordinates, not in an
    // NSTrackingArea on the content view. A tracking area moves with the
    // content, and toggling the toolbar resizes the content, so the area slid
    // out from under a stationary pointer and the enter/exit pair repeated
    // without end.
    private func startPointerTracking() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.updateFullScreenBar()
            return event
        }
        // Without this the window drops mouse-moved events and the monitor
        // above never sees a pointer that only hovers.
        savedAcceptsMouseMoved = window?.acceptsMouseMovedEvents
        window?.acceptsMouseMovedEvents = true
        updateFullScreenBar()
    }

    private func stopPointerTracking() {
        if let monitor = pointerMonitor {
            NSEvent.removeMonitor(monitor)
            pointerMonitor = nil
        }
        if let saved = savedAcceptsMouseMoved {
            window?.acceptsMouseMovedEvents = saved
            savedAcceptsMouseMoved = nil
        }
    }

    private func updateFullScreenBar() {
        guard let window, window.styleMask.contains(.fullScreen),
              let screen = window.screen else { return }
        let pointerY = NSEvent.mouseLocation.y
        let screenTop = screen.frame.maxY

        if window.toolbar == nil {
            guard let toolbar = savedToolbar, pointerY >= screenTop - Self.revealEdge else { return }
            window.toolbar = toolbar
        } else {
            // Measure the bar rather than assume its height: the top of the
            // content view in screen coordinates is exactly where it ends.
            guard let content = window.contentView else { return }
            let contentTop = window.convertPoint(toScreen: NSPoint(x: 0, y: content.frame.maxY)).y
            if pointerY < contentTop - Self.hideSlack { window.toolbar = nil }
        }
    }
}
