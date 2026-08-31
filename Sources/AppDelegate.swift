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
    private var bridge: GhosttyBridge!        // must be retained or its observers die
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
        bridge = GhosttyBridge(sessions: sessions, ghostty: ghostty)

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

        // showWindow only orders front; a window that never becomes key eats
        // the first keystrokes (menu key equivalents need a key window), so
        // force the key state and put the terminal surface on deck.
        if let window = windowController.window, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        if let session = sessions.selected {
            windowController.window?.makeFirstResponder(session.view)
        }
    }

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        sessions.surface(for: uuid)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func buildMenus() {
        NSApp.mainMenu = MainMenu.build(target: self)
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
