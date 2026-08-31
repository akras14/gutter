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

    private var windowController: MainWindowController!
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
        _ = GhosttyBridge(sessions: sessions, ghostty: ghostty)

        let windowController = MainWindowController(sessions: sessions)
        self.windowController = windowController

        buildMenus()

        sessions.onListChanged = { [weak windowController] in
            windowController?.splitVC.sidebarReload()
        }
        sessions.onSelectionChanged = { [weak windowController] session in
            guard let split = windowController?.splitVC else { return }
            split.show(session)
            split.view.window?.makeFirstResponder(session?.view)
        }

        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        sessions.newSession(app: app)
    }

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        sessions.surface(for: uuid)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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
        windowController?.splitVC.toggleSidebar(sender)
    }
}
