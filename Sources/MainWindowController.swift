import AppKit
import GhosttyKit

/// Owns the main window: frame sizing, the split shell, the toolbar, and
/// fullscreen chrome. Every piece of "window" logic lives here; AppDelegate
/// only creates this and forwards actions to it.
///
/// It subclasses `BaseTerminalController` (Gutter's shim, `Shims.swift`) because
/// ghostty's core refuses to perform `goto_split`, `resize_split` and
/// `toggle_split_zoom` unless the key window's controller is one, and reads the
/// pane tree and focused surface off it to decide whether the keybind is even
/// performable (`Ghostty.App.swift:1168,1274,1328`). Keeping `surfaceTree` and
/// `focusedSurface` current - `syncSplitState` - is the whole of that contract.
final class MainWindowController: BaseTerminalController, NSWindowDelegate, NSToolbarDelegate {
    /// Default content size, clamped to the visible screen at launch.
    static let defaultContentSize = NSSize(width: 1750, height: 1120)
    static let sidebarWidth: CGFloat = 330

    private let splitVC: MainSplitViewController
    private let sessions: SessionManager
    private var diffWindow: GitDiffWindowController?

    init(sessions: SessionManager, ghostty: Ghostty.App) {
        let split = MainSplitViewController(sessions: sessions, ghostty: ghostty)
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
            guard let self else { return }
            self.splitVC.sidebarReload()
            self.updateDockBadge()
            self.syncSplitState()
        }
        sessions.onSelectionChanged = { [weak self] session in
            guard let self else { return }
            self.splitVC.show(session)
            // moveFocus, not makeFirstResponder: the surface is inside a
            // SwiftUI tree now and may not be attached to the window yet on
            // the first pass. Ghostty's helper retries with a backoff, which
            // is exactly the case it exists for.
            if let session { Ghostty.moveFocus(to: session.view) }
        }
        sessions.onTreeChanged = { [weak self] session in
            guard let self else { return }
            self.splitVC.refresh(session)
            self.syncSplitState()
        }
        // Last tab gone: close the window. applicationShouldTerminateAfter-
        // LastWindowClosed then quits the app. close(), not performClose():
        // the latter consults the delegate and can be vetoed.
        sessions.onEmpty = { [weak self] in
            self?.window?.close()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// What the core reads to decide whether a split keybind can fire, and
    /// which pane it fires from. See the note on the class.
    private func syncSplitState() {
        surfaceTree = sessions.selected?.tree ?? SplitTree<Ghostty.SurfaceView>()
        focusedSurface = sessions.selected?.view
    }

    /// Both are `BaseTerminalController` entry points that only became live
    /// when this became one: the core's `prompt_surface_title` action for a tab
    /// (`Ghostty.App.swift:1681,1690`), and the right-click menu's "Change Tab
    /// Title...". Gutter's tab title is the sidebar row's name, so both land on
    /// the rename that cmd-shift-R starts.
    override func promptTabTitle() {
        beginRenameSelectedTab()
    }

    override func changeTabTitle(_ sender: Any) {
        beginRenameSelectedTab()
    }

    /// The sidebar dot only reaches you while you are looking at Gutter, which
    /// is the opposite of what the app is for: start several agents, go away,
    /// come back when one wants you. The Dock badge is that same state -
    /// `Session.needsAttention`, counted - somewhere you see without switching
    /// apps. No bounce: with several agents a bounce per hand-off is constant
    /// motion, and the badge is already there on the next glance.
    ///
    /// The tile belongs to NSApp, but this lives here because this is where
    /// every session -> UI reaction lives; `SessionManager` is the model and
    /// holds no AppKit policy.
    private func updateDockBadge() {
        let count = sessions.attentionCount
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

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
            item.toolTip = "Show changes in this session's directory"
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

// Rendering follows the window: minimized, hidden behind another app, or fully
// covered, and nothing draws. `SessionManager.syncOcclusion` owns the other
// half of that decision - which session is selected - and the reasoning.
extension MainWindowController {
    func windowDidChangeOcclusionState(_ notification: Notification) {
        sessions.setWindowVisible(window?.occlusionState.contains(.visible) ?? false)
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
        Ghostty.moveFocus(to: session.view)
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
