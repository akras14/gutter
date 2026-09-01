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
    private var diffWindow: GitDiffWindowController?

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

// Fullscreen chrome: the top bar auto-hides for the duration of native
// fullscreen and slides back when the pointer reaches the top edge.
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

    // AppKit keeps a window's toolbar on screen in fullscreen unless the app
    // asks otherwise, so ask: .autoHideToolbar makes the toolbar slide away
    // with the menu bar and slide back on a pointer at the top edge, which is
    // exactly the wanted behavior and is animated by the system.
    //
    // This replaces a hand-rolled version that swapped `window.toolbar` in and
    // out while fullscreen. That churn broke the bar: re-attaching a toolbar
    // mid-fullscreen left it without its items and at the wrong height, and the
    // damaged toolbar was then restored on the way out. Don't reintroduce it.
    //
    // .autoHideToolbar is only legal alongside .fullScreen and .autoHideMenuBar.
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions)
    -> NSApplication.PresentationOptions {
        [proposed, .fullScreen, .autoHideMenuBar, .autoHideToolbar]
    }
}
