import AppKit
import GhosttyKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate, GhosttyAppDelegate {
    /// The libghostty app + config. Prefers the user's existing Ghostty app
    /// config (theme/font live there, not in ~/.config/ghostty); falls back
    /// to libghostty's default file search when it doesn't exist.
    static let configPath = ("~/Library/Application Support/com.mitchellh.ghostty/config.ghostty" as NSString).expandingTildeInPath
    let ghostty = Ghostty.App(configPath: FileManager.default.fileExists(atPath: AppDelegate.configPath) ? AppDelegate.configPath : nil)

    /// Referenced by vendored SurfaceView menu code.
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.akras.gutter", category: "app")

    // MARK: Members the vendored Ghostty sources call on NSApp.delegate.
    // All are unreachable or intentionally inert in Gutter (no updates
    // checker, no quick terminal, no floating windows), but the symbols must
    // exist for the casts to compile.
    let undoManager: UndoManager? = nil
    func checkForUpdates(_ sender: Any?) {}
    func closeAllWindows(_ sender: Any?) { NSApp.windows.forEach { $0.performClose(nil) } }
    func toggleVisibility(_ sender: Any?) {}
    func syncFloatOnTopMenu(_ window: NSWindow) {}
    func setSecureInput(_ mode: Ghostty.SetSecureInput) {}
    func toggleQuickTerminal(_ sender: Any?) {}
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool { false }

    private var window: NSWindow!
    private var splitVC: MainSplitViewController?
    private var savedToolbar: NSToolbar?
    private var topEdgeArea: NSTrackingArea?
    let sessions = SessionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ghostty.readiness == .ready, let app = ghostty.app else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to load Ghostty config"
            alert.informativeText = "Check your Ghostty config (~/.config/ghostty/config). See Console.app for Ghostty logs."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        ghostty.delegate = self
        sessions.requestClose = { [weak self] view in
            guard let self, let surface = view.surface else { return }
            self.ghostty.requestClose(surface: surface)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Gutter"
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("Gutter Main Window")
        window.delegate = self

        let split = MainSplitViewController(sessions: sessions)
        window.contentViewController = split
        window.center()
        self.window = window
        self.splitVC = split

        buildMenus()

        sessions.onListChanged = { [weak split] in split?.sidebarReload() }
        sessions.onSelectionChanged = { [weak split] session in
            split?.show(session)
            split?.view.window?.makeFirstResponder(session?.view)
        }

        NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main
        ) { [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            guard let session = self?.sessions.sessions.first(where: { $0.view === view }) else { return }
            self?.sessions.remove(session)
        }

        // Ghostty's own keybinds (cmd-t/cmd-w etc.) are consumed by the core and
        // emitted as app actions; wire them to the session manager so the user's
        // configured keybinds work as-is.
        NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyNewTab, object: nil, queue: .main
        ) { [weak self] _ in
            self?.newTab(nil)
        }
        NotificationCenter.default.addObserver(
            forName: .ghosttyCloseTab, object: nil, queue: .main
        ) { [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            if let session = self?.sessions.sessions.first(where: { $0.view === view }) {
                self?.sessions.close(session)
            }
        }
        NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyGotoTab, object: nil, queue: .main
        ) { [weak self] note in
            guard let any = note.userInfo?[Ghostty.Notification.GotoTabKey],
                  let tab = any as? ghostty_action_goto_tab_e else { return }
            let raw = tab.rawValue
            if raw > 0 {
                self?.sessions.select(index: Int(raw) - 1)
            } else if raw == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                self?.sessions.cycle(-1)
            } else if raw == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                self?.sessions.cycle(1)
            }
        }

        // Ghostty's toggle_fullscreen action -> native fullscreen on the surface's window.
        NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyToggleFullscreen, object: nil, queue: .main
        ) { note in
            (note.object as? Ghostty.SurfaceView)?.window?.toggleFullScreen(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        sessions.newSession(app: app)
    }

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        sessions.surface(for: uuid)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Gutter",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Gutter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Gutter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(newTab(_:)), keyEquivalent: "t").target = self
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(closeTab(_:)), keyEquivalent: "w").target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let sidebar = viewMenu.addItem(withTitle: "Toggle Sidebar",
                                       action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        sidebar.target = self
        viewMenu.addItem(.separator())
        for i in 1...9 {
            let item = viewMenu.addItem(withTitle: "Select Tab \(i)",
                                        action: #selector(selectTab(_:)), keyEquivalent: "\(i)")
            item.tag = i - 1
            item.target = self
        }
        viewMenu.addItem(.separator())
        let next = viewMenu.addItem(withTitle: "Show Next Tab",
                                    action: #selector(nextTab(_:)), keyEquivalent: "\t")
        next.keyEquivalentModifierMask = [.control]
        next.target = self
        let prev = viewMenu.addItem(withTitle: "Show Previous Tab",
                                    action: #selector(previousTab(_:)), keyEquivalent: "\t")
        prev.keyEquivalentModifierMask = [.control, .shift]
        prev.target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: Menu actions (explicit targets - see buildMenus)

    @objc func newTab(_ sender: Any?) {
        Self.logger.info("newTab requested (menu)")
        guard let app = ghostty.app else { return }
        sessions.newSession(app: app)
    }

    @objc func closeTab(_ sender: Any?) {
        sessions.closeSelected()
    }

    @objc func selectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        sessions.select(index: item.tag)
    }

    @objc func nextTab(_ sender: Any?) {
        sessions.cycle(1)
    }

    @objc func previousTab(_ sender: Any?) {
        sessions.cycle(-1)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        splitVC?.toggleSidebar(sender)
    }
}

extension AppDelegate: NSToolbarDelegate {
    private static let sidebarID = NSToolbarItem.Identifier("sidebar")

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
        item.action = #selector(toggleSidebar(_:))
        item.target = self
        item.isBordered = true
        return item
    }
}

// Fullscreen chrome: the top bar (toolbar) is removed for the duration of
// native fullscreen and only slides back while the pointer is in the top strip
// of the screen. Exiting fullscreen always restores it.
extension AppDelegate: NSWindowDelegate {
    private static let topEdgeHeight: CGFloat = 40

    func windowWillEnterFullScreen(_ notification: Notification) {
        // Drop it before the transition zooms so it never floats over the content.
        savedToolbar = window.toolbar
        window.toolbar = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        installTopEdgeTracking()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        removeTopEdgeTracking()
        window.toolbar = savedToolbar
        savedToolbar = nil
    }

    @objc func mouseEntered(_ event: NSEvent) {
        guard window.styleMask.contains(.fullScreen), window.toolbar == nil,
              let toolbar = savedToolbar else { return }
        window.toolbar = toolbar
    }

    @objc func mouseExited(_ event: NSEvent) {
        guard window.styleMask.contains(.fullScreen), window.toolbar != nil else { return }
        window.toolbar = nil
    }

    private func installTopEdgeTracking() {
        guard let content = window.contentView, topEdgeArea == nil else { return }
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
            window.contentView?.removeTrackingArea(area)
            topEdgeArea = nil
        }
    }
}
