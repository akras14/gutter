import AppKit
import GhosttyKit

/// Owns one main window: frame sizing, the split shell, the toolbar, and
/// fullscreen chrome. Every piece of "window" logic lives here; AppDelegate
/// owns the list of them and forwards actions to whichever is in front.
///
/// There can be several. Each one has its own `SessionManager`, so a window is
/// a whole independent sidebar of sessions; the three closures below are how
/// AppDelegate keeps its list, the Dock badge and the front-window order in
/// step without this class knowing about the others.
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
    let sessions: SessionManager
    private var diffWindow: GitDiffWindowController?

    /// Something in this window's sessions changed - AppDelegate re-counts the
    /// Dock badge, which is app-wide and so can't be set from here.
    var onSessionsChanged: (() -> Void)?
    /// This window became key: it is the front one now.
    var onBecomeKey: ((MainWindowController) -> Void)?
    /// This window is going away; drop it from the list.
    var onClose: ((MainWindowController) -> Void)?

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

        // Frames are ours to place (`cascade(from:)`), not AppKit's: without
        // this it cascades any window that has no frame autosave name, which
        // is every window after the first, on top of the offset we just gave
        // it.
        shouldCascadeWindows = false

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
        // Only one window at a time can hold an autosave name - AppKit hands
        // it to the first claimant and refuses the rest, which is exactly the
        // test for "am I the first window". The others open at the default
        // size and are cascaded and sized by AppDelegate (`cascade(from:)`),
        // rather than remembering a frame and a sidebar width that would fight
        // with the first window's over the same defaults key.
        let hasSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame Gutter Main Window") != nil
        let isFirstWindow = window.setFrameAutosaveName("Gutter Main Window")
        if isFirstWindow, !hasSavedFrame {
            window.center()
        }
        let hasSavedSplit = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames Gutter Main Split") != nil
        if isFirstWindow {
            split.splitView.autosaveName = "Gutter Main Split"
        }
        if !isFirstWindow || !hasSavedSplit {
            split.setSidebarWidth(Self.sidebarWidth)
        }

        // The window owns session -> UI wiring: sidebar refresh, showing the
        // selected surface, and handing it first responder.
        sessions.onListChanged = { [weak self] in
            guard let self else { return }
            self.splitVC.sidebarReload()
            self.onSessionsChanged?()
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
        // Last tab gone: close this window. With no window left,
        // applicationShouldTerminateAfterLastWindowClosed then quits the app;
        // with another one open, the app simply carries on there. close(), not
        // performClose(): the latter consults the delegate and can be vetoed.
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

    /// Open beside `other` instead of on top of it. Only the first window
    /// restores a remembered frame, so every one after it would otherwise
    /// arrive at the same default size in the same place. The sidebar width
    /// comes across too, so a new window looks like the one it came from.
    func cascade(from other: MainWindowController) {
        guard let window, let previous = other.window else { return }
        window.setFrame(previous.frame, display: false)
        window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
        // Zero while the sidebar is collapsed - inheriting that would open a
        // window with no sidebar and no obvious way back to one.
        if other.sidebarWidth > 0 { splitVC.setSidebarWidth(other.sidebarWidth) }
    }

    var sidebarWidth: CGFloat { splitVC.sidebarWidth }

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

    /// Closing a window closes everything in it: AppDelegate drops the last
    /// reference to this controller, which releases the sessions, their panes
    /// and their surfaces. There is no confirmation - the same as it has always
    /// been for the last window, which quit the app.
    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

// Fullscreen chrome: the top bar auto-hides for the duration of native
// fullscreen and slides back when the pointer reaches the top edge.
extension MainWindowController {
    func windowDidBecomeKey(_ notification: Notification) {
        // This is the front window now: the menu bar acts on its sessions.
        onBecomeKey?(self)

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
