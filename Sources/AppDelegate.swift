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
    /// Lazy, not implicitly unwrapped: a Gutter patch in
    /// Vendor/Ghostty/Ghostty.App.swift reads `delegate?.sessions.sessions.count`,
    /// which would force-unwrap. Lazy keeps it non-optional while still
    /// letting it take `ghostty` (a stored property can't reference another).
    private(set) lazy var sessions = SessionManager(ghostty: ghostty)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ghostty.readiness == .ready, ghostty.app != nil else {
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

        // Create the first session before showing the window: windowDidBecomeKey
        // (which hands first responder to the terminal surface) fires during
        // showWindow, and needs a selected session to exist by then.
        sessions.newSession()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        sessions.newSession()
    }

    // cmd-w is a menu key equivalent, so it fires whichever window is key -
    // including the diff window, which would otherwise have closed a terminal
    // tab behind the user's back. Close the key window instead and hand focus
    // back to the main one; only the main window closes a session.
    @objc func closeTab(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== windowController.window {
            key.performClose(sender)
            windowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        sessions.closeSelected()
    }

    @objc func showGitDiff(_ sender: Any?) {
        windowController.showGitDiff(sender)
    }

    private var shortcutsWindow: ShortcutsWindowController?

    @objc func showShortcuts(_ sender: Any?) {
        let controller = shortcutsWindow ?? ShortcutsWindowController()
        shortcutsWindow = controller
        controller.present()
    }

    // MARK: Config actions
    //
    // Not the vendored `Ghostty.App.openConfig()`: that opens whatever
    // `ghostty_config_open_path()` returns (~/.config/ghostty/config), which
    // is not the file Gutter loads when Ghostty.app's own config exists.

    /// The file the Config menu edits: the one libghostty loaded, or the
    /// default path it would search if that file doesn't exist yet.
    private static var editableConfigPath: String {
        FileManager.default.fileExists(atPath: configPath)
            ? configPath
            : ("~/.config/ghostty/config" as NSString).expandingTildeInPath
    }

    @objc func openConfigFile(_ sender: Any?) {
        let url = URL(fileURLWithPath: Self.editableConfigPath)

        // Nothing to edit on a machine with no Ghostty config at all; make an
        // empty one (and its directory) so the editor has a file to open.
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "# Ghostty configuration. See https://ghostty.org/docs/config\n".write(
                    to: url, atomically: true, encoding: .utf8)
            } catch {
                Self.alert(title: "Could not create the config file",
                           message: "\(url.path)\n\n\(error.localizedDescription)")
                return
            }
        }

        // `open -t` is the system's default text editor. It has to go through
        // /usr/bin/open: nothing claims `.ghostty` (its UTI resolves to a
        // dynamic type under public.data), so NSWorkspace.open pops the "no
        // application set to open the document" panel, and NSWorkspace's app
        // lookups return nil from inside this bundle even where the same call
        // resolves fine in a plain command-line binary.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-t", url.path]
        if (try? open.run()) != nil {
            open.waitUntilExit()
            if open.terminationStatus == 0 { return }
        }
        // No text editor at all: show the file in Finder rather than leaving
        // the menu item looking broken.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func reloadConfigFile(_ sender: Any?) {
        ghostty.reloadConfig()
        // reloadConfig() only logs a bad config, so surface the diagnostics
        // here - a silent no-op after editing the file is worse than an alert.
        let errors = ghostty.config.errors
        if !errors.isEmpty {
            Self.alert(title: "Ghostty config errors", message: errors.joined(separator: "\n"))
        }
    }

    private static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @objc func renameTab(_ sender: Any?) {
        windowController.beginRenameSelectedTab()
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

    // MARK: Find actions
    //
    // Deliberately not named findNext:/findPrevious:: the vendored SurfaceView
    // defines those selectors and sends `search:next` / `search:previous`,
    // which sets the *needle* to the literal text "next" rather than moving
    // between matches (`navigate_search:` is the action that navigates). Using
    // distinct names keeps a stray responder-chain dispatch off that path.
    // Everything else lands on searchState, which raises the find bar.

    @objc func findInTerminal(_ sender: Any?) {
        guard let view = sessions.selected?.view else { return }
        GhosttyBridge.perform("start_search", on: view)
    }

    @objc func findNextMatch(_ sender: Any?) {
        guard let view = sessions.selected?.view else { return }
        GhosttyBridge.perform("navigate_search:next", on: view)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        guard let view = sessions.selected?.view else { return }
        GhosttyBridge.perform("navigate_search:previous", on: view)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard let view = sessions.selected?.view else { return }
        GhosttyBridge.perform("search_selection", on: view)
    }
}
