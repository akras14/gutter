import AppKit
import GhosttyKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate, GhosttyAppDelegate, NSMenuItemValidation {
    /// The libghostty app + config. Gutter has its own config file, in
    /// ghostty's syntax; ghostty's own default files are never loaded, so
    /// Ghostty.app's config stays Ghostty.app's. To inherit it, add a
    /// `config-file = ?~/.config/ghostty/config` line here.
    /// Passing a path that doesn't exist is safe: libghostty logs a
    /// FileNotFound and the config stays at ghostty's built-in defaults.
    static let configPath = ("~/.config/gutter/config" as NSString).expandingTildeInPath
    let ghostty = Ghostty.App(configPath: AppDelegate.configPath)

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

    /// Every open main window, most recently focused last: `front` is
    /// `windows.last`, and becoming key moves a window there. Nothing
    /// is shared between two windows - each has its own sessions, sidebar and
    /// changes window - so "which window" is the same question as "which
    /// session list", and every menu action asks it.
    private var windows: [MainWindowController] = []
    /// Live only while the New Request sheet is up.
    private var requestSheet: NewRequestSheet?
    private var bridge: GhosttyBridge!        // must be retained or its observers die

    /// The window the menu acts on: the key one, or the last that was key.
    var front: MainWindowController? { windows.last }

    /// The front window's sessions. Every `sessions.` call in this file means
    /// "the window the user is looking at", which is why the menu actions read
    /// unchanged from when there was only one.
    ///
    /// Non-optional deliberately: a Gutter patch in
    /// `Vendor/Ghostty/Ghostty.App.swift` reads
    /// `delegate?.sessions.sessions.count` and wouldn't compile against an
    /// optional. `spareSessions` is never reached - that patch runs off a
    /// surface, and a surface only exists inside a window.
    var sessions: SessionManager { front?.sessions ?? spareSessions }
    private lazy var spareSessions = SessionManager(ghostty: ghostty)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ghostty.readiness == .ready, ghostty.app != nil else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to load config"
            alert.informativeText = "Check your Gutter config (\(AppDelegate.configPath)). See Console.app for Ghostty logs."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        ghostty.delegate = self
        bridge = GhosttyBridge(app: self, ghostty: ghostty)

        // First launch on a machine with no Gutter config: create the (empty)
        // file so cmd-, has something to open. Silent - an empty file changes
        // nothing about this launch, so a failure here isn't worth an alert.
        Self.ensureConfigFile(alerting: false)
        LauncherConfig.ensureFile()

        buildMenus()
        openWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        windows.lazy.compactMap { $0.sessions.surface(for: uuid) }.first
    }

    // MARK: Windows

    /// Opens a main window. Everything below the window is per-window: its own
    /// `SessionManager`, its own sidebar, its own changes window. The one thing
    /// two windows share is libghostty itself - one `Ghostty.App`, one config,
    /// one notification stream, which is why `GhosttyBridge` has to route by
    /// surface (see that file).
    ///
    /// `config` is what the new window's first session inherits - the working
    /// directory above all - from the surface the window was opened from.
    @discardableResult
    func openWindow(config: Ghostty.SurfaceConfiguration? = nil) -> MainWindowController {
        let sessions = SessionManager(ghostty: ghostty)
        let controller = MainWindowController(sessions: sessions, ghostty: ghostty)
        controller.onSessionsChanged = { [weak self] in self?.updateDockBadge() }
        controller.onBecomeKey = { [weak self] controller in
            guard let self, self.windows.last !== controller else { return }
            self.windows.removeAll { $0 === controller }
            self.windows.append(controller)
        }
        controller.onClose = { [weak self] controller in
            // Next tick, not now: this fires from windowWillClose, and
            // dropping the last reference to a window controller in the middle
            // of AppKit's own close sequence takes the window down with it.
            DispatchQueue.main.async {
                self?.windows.removeAll { $0 === controller }
                self?.updateDockBadge()
            }
        }

        // Open beside the window this one came from rather than exactly on top
        // of it: only one window can hold the frame autosave name, so the rest
        // arrive at the default size in the default place.
        if let previous = front {
            controller.cascade(from: previous)
        }
        windows.append(controller)

        // Create the first session before showing the window: windowDidBecomeKey
        // (which hands first responder to the terminal surface) fires during
        // showWindow, and needs a selected session to exist by then.
        sessions.newSession(config: config)
        controller.showWindow(nil)
        return controller
    }

    /// File > New Window, and the Dock icon's menu. With a surface focused the
    /// ghostty core claims ⌘N first (its own macOS default,
    /// `super+n=new_window`) and the action comes back through
    /// `GhosttyBridge`; this is the same key from the menu bar, for when focus
    /// is in the sidebar. Both inherit the current session's directory.
    @objc func newWindow(_ sender: Any?) {
        Self.logger.info("newWindow requested (menu)")
        openWindow(config: sessions.selected.flatMap {
            GhosttyBridge.inheritedConfig(from: $0.view, context: GHOSTTY_SURFACE_CONTEXT_WINDOW)
        })
    }

    /// The window a surface lives in. `GhosttyBridge` asks this of every
    /// notification libghostty posts: they are app-wide, and the surface in
    /// the payload is the only thing saying which window they belong to.
    func window(owning view: Ghostty.SurfaceView) -> MainWindowController? {
        windows.first { $0.sessions.session(for: view) != nil }
    }

    /// The Dock badge counts every window's sessions. It lives here rather than
    /// in a window controller (where it started) because the tile belongs to
    /// the app: with two windows open, a badge set from one of them would keep
    /// overwriting the other's count.
    private func updateDockBadge() {
        let count = windows.reduce(0) { $0 + $1.sessions.attentionCount }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    /// Right-clicking the Dock icon. AppKit fills in the window list and Quit;
    /// New Window is ours, and is the one way into a new window without
    /// bringing Gutter forward first.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)),
                     keyEquivalent: "").target = self
        return menu
    }

    /// Clicking the Dock icon of a running Gutter. Closing the last main window
    /// quits the app, so this only fires while something else is holding it
    /// open - the changes or shortcuts window - and it is the way back to a
    /// terminal from there. Returning true leaves AppKit's own unminimize
    /// behavior alone for the ordinary case.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if windows.isEmpty { openWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func buildMenus() {
        NSApp.mainMenu = MainMenu.build(target: self)
    }

    // MARK: Menu actions (explicit targets - see buildMenus)

    // The menu's cmd-t never reaches a surface, so no ghostty notification
    // carries the inherited config here. Ask libghostty for it directly,
    // against the session the user is looking at, so both cmd-t paths open in
    // the same directory.
    @objc func newTab(_ sender: Any?) {
        Self.logger.info("newTab requested (menu)")
        sessions.newSession(config: sessions.selected.flatMap {
            GhosttyBridge.inheritedConfig(from: $0.view)
        })
    }

    /// Fires a request off into a new tab: the folder the current session is
    /// in, the command the launchers file picks for that folder, and no change
    /// of focus - the new session runs in the background.
    @objc func newRequest(_ sender: Any?) {
        let launchers = LauncherConfig.load()
        let directory = sessions.selected.flatMap {
            GhosttyBridge.inheritedConfig(from: $0.view)?.workingDirectory
        } ?? sessions.selected?.pwd

        guard !launchers.choices(for: directory).isEmpty else {
            Self.alert(title: "No launchers configured",
                       message: "Add a line like `launcher = claude` to \(LauncherConfig.path).")
            return
        }

        // Held for the life of the sheet: NSAlert doesn't retain its delegate,
        // and the sheet is asynchronous.
        let sheet = NewRequestSheet(launchers: launchers,
                                    folders: requestFolders(current: directory, launchers: launchers))
        requestSheet = sheet
        sheet.present(in: front?.window) { [weak self] request in
            self?.requestSheet = nil
            guard let request else { return }
            self?.launchRequest(command: request.command,
                                directory: request.directory,
                                prompt: request.prompt)
        }
    }

    /// What the sheet's folder popup offers: where you are, where your other
    /// tabs are, then whatever the launchers file names. First mention wins, so
    /// the current folder stays at the top and comes preselected - and a folder
    /// you have a tab open in never needs a config line.
    private func requestFolders(current: String?, launchers: LauncherConfig) -> [String] {
        var seen = Set<String>()
        let all = [current].compactMap { $0 }
            + sessions.sessions.compactMap { $0.pwd }
            + launchers.folders
            + launchers.folderDefaults.map { $0.prefix }
        return all.filter { seen.insert($0).inserted }
    }

    /// The one place a launcher-started session is built. `command` and
    /// `directory` nil mean "whatever the current session and the launchers
    /// file say", which is what the menu item passes.
    func launchRequest(command: String? = nil, directory: String? = nil, prompt: String) {
        // Start from what a plain new tab would inherit (working directory,
        // font size, whatever the user's *-inherit-* keys turn on), then
        // override only what the request specifies.
        var config = sessions.selected.flatMap { GhosttyBridge.inheritedConfig(from: $0.view) }
            ?? Ghostty.SurfaceConfiguration()
        if let directory { config.workingDirectory = directory }

        let launchers = LauncherConfig.load()
        guard let command = command ?? launchers.command(for: config.workingDirectory) else {
            Self.alert(title: "No launchers configured",
                       message: "Add a line like `launcher = claude` to \(LauncherConfig.path).")
            return
        }

        // Typed into the session's shell rather than spawned as the surface's
        // `command`: an interactive shell is where the user's aliases live
        // (`pclaude` is one), and it survives the tool exiting, so the tab
        // stays usable in that folder afterwards.
        config.initialInput = LauncherConfig.commandLine(command, prompt: prompt)
        Self.logger.info("newRequest command=\(command, privacy: .public)")
        sessions.newSession(config: config, select: false)
    }

    // cmd-w is a menu key equivalent, so it fires whichever window is key -
    // including the diff window, which would otherwise have closed a terminal
    // pane behind the user's back. Close the key window instead and hand focus
    // back to the front main window; only a main window closes a pane. A main
    // window that isn't the front one can't be key, so the test is "is the key
    // window one of ours at all".
    //
    // cmd-w closes one pane and alt-cmd-w the whole session, matching ghostty,
    // where they are close_surface and close_tab. Both go through the core so
    // that a pane running something gets its confirmation prompt; it comes back
    // as ghosttyCloseSurface, and closing a session's last pane is what removes
    // the sidebar row.
    @objc func closePane(_ sender: Any?) {
        if let key = NSApp.keyWindow, !(key.windowController is MainWindowController) {
            key.performClose(sender)
            front?.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let surface = sessions.selected?.view.surface else { return }
        ghostty.requestClose(surface: surface)
    }

    @objc func closeSession(_ sender: Any?) {
        sessions.closeSelected()
    }

    @objc func showGitDiff(_ sender: Any?) {
        front?.showGitDiff(sender)
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
    // is ghostty's file, not the one Gutter loads.

    /// Creates `configPath` (and its directory) when it doesn't exist yet, so
    /// the Config menu always has a file to open. Only ever creates it: an
    /// existing file is someone's own and is never rewritten.
    ///
    /// The template carries one live setting, `notify-on-command-finish`. It
    /// is a seed and not an override on purpose: written into the user's file,
    /// it can be edited or deleted like anything else they put there, where
    /// the same line in the embedder config `main.swift` writes would win over
    /// their config and could never be turned off. The cost is that it only
    /// reaches a machine that hasn't run Gutter before - see DESIGN.md.
    ///
    /// Returns false and alerts when creation fails.
    @discardableResult
    private static func ensureConfigFile(alerting: Bool) -> Bool {
        let url = URL(fileURLWithPath: configPath)
        if FileManager.default.fileExists(atPath: url.path) { return true }
        let template = """
        # Gutter config, in ghostty's config syntax: theme, font-size, keybinds.
        #
        # The settings worth knowing about, and the keys Gutter claims:
        # https://github.com/akras14/gutter/blob/master/CONFIG.md
        # Every ghostty option: https://ghostty.org/docs/config
        #
        # Ghostty's own config files are never loaded. To inherit yours:
        #
        #   config-file = ?~/.config/ghostty/config
        #
        # Light a session's sidebar dot - and the Dock badge - when a command
        # that ran for a while finishes in a tab you aren't looking at. Coding
        # agents report themselves; this is what a plain shell has, for a build
        # or a test run. Needs shell integration, which Gutter bundles.
        # Delete the line to turn it off; notify-on-command-finish-after
        # changes the 5s it has to have been running for.
        notify-on-command-finish = unfocused

        """
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try template.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            if alerting {
                alert(title: "Could not create the config file",
                      message: "\(url.path)\n\n\(error.localizedDescription)")
            }
            return false
        }
    }

    /// Opens both config files at once. They are split for libghostty's sake,
    /// not the user's - one parses the ghostty file and diagnoses keys it
    /// doesn't know, so Gutter's launchers need their own - and making the user
    /// remember which key lives where would be that split leaking out.
    @objc func openConfigFile(_ sender: Any?) {
        let url = URL(fileURLWithPath: Self.configPath)
        guard Self.ensureConfigFile(alerting: true) else { return }
        LauncherConfig.ensureFile()
        let launchers = URL(fileURLWithPath: LauncherConfig.path)

        // `open -t` is the system's default text editor. It has to go through
        // /usr/bin/open: nothing claims this file type (its UTI resolves to a
        // dynamic type under public.data), so NSWorkspace.open pops the "no
        // application set to open the document" panel, and NSWorkspace's app
        // lookups return nil from inside this bundle even where the same call
        // resolves fine in a plain command-line binary.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-t", url.path, launchers.path]
        if (try? open.run()) != nil {
            open.waitUntilExit()
            if open.terminationStatus == 0 { return }
        }
        // No text editor at all: show the file in Finder rather than leaving
        // the menu item looking broken.
        NSWorkspace.shared.activateFileViewerSelecting([url, launchers])
    }

    @objc func reloadConfigFile(_ sender: Any?) {
        ghostty.reloadConfig()
        // reloadConfig() only logs a bad config, so surface the diagnostics
        // here - a silent no-op after editing the file is worse than an alert.
        let errors = ghostty.config.errors
        if !errors.isEmpty {
            Self.alert(title: "Gutter config errors", message: errors.joined(separator: "\n"))
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
        front?.beginRenameSelectedTab()
    }

    @objc func renameWindow(_ sender: Any?) {
        front?.beginRenameWindow()
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

    /// Walk the sessions that want the user - the same dots the sidebar shows
    /// and the Dock badge counts. Selecting one clears its dot, so repeating
    /// this empties the queue.
    ///
    /// The badge counts every window, so the walk has to cross windows too, or
    /// it would stall on a count it can't reach. The front window is emptied
    /// first, then the next window holding a dot is brought forward.
    @objc func nextAttentionTab(_ sender: Any?) {
        if let next = front?.sessions.nextNeedingAttention {
            front?.sessions.selectForAttention(next)
            return
        }
        guard let (window, session) = otherWindowNeedingAttention() else { return }
        window.window?.makeKeyAndOrderFront(nil)
        window.sessions.selectForAttention(session)
    }

    /// The next window with a dot in it, searched from the front backwards -
    /// `windows` is in focus order, so that is most-recently-used first.
    private func otherWindowNeedingAttention() -> (MainWindowController, Session)? {
        for window in windows.reversed() where window !== front {
            if let session = window.sessions.sessions.first(where: \.needsAttention) {
                return (window, session)
            }
        }
        return nil
    }

    /// Only one item is ever disabled: jumping to a session that wants you,
    /// when none does. Everything else this delegate targets is always
    /// available, and AppKit's default for an unvalidated item is enabled, so
    /// the rest of the menu is unchanged by returning true.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(nextAttentionTab(_:)) else { return true }
        return front?.sessions.nextNeedingAttention != nil || otherWindowNeedingAttention() != nil
    }

    // MARK: Find actions
    //
    // Deliberately not named findNext:/findPrevious:: the vendored SurfaceView
    // defines those selectors and sends `search:next` / `search:previous`,
    // which sets the *needle* to the literal text "next" rather than moving
    // between matches (`navigate_search:` is the action that navigates). Using
    // distinct names keeps a stray responder-chain dispatch off that path.
    // Everything else lands on searchState, which raises the find bar.
    //
    // The changes window has a find bar of its own, over its two panes. While
    // it is key these belong to it - otherwise ⌘F there would open the
    // terminal's find bar in the window behind it.

    private var keyDiffWindow: GitDiffWindowController? {
        NSApp.keyWindow?.windowController as? GitDiffWindowController
    }

    @objc func findInTerminal(_ sender: Any?) {
        if let diff = keyDiffWindow { return diff.beginFind() }
        guard let view = sessions.selected?.view else { return }
        GhosttyBridge.perform("start_search", on: view)
    }

    @objc func findNextMatch(_ sender: Any?) {
        if let diff = keyDiffWindow { return diff.stepFind(forward: true) }
        guard let view = sessions.selected?.view else { return }
        GhosttyBridge.perform("navigate_search:next", on: view)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        if let diff = keyDiffWindow { return diff.stepFind(forward: false) }
        guard let view = sessions.selected?.view else { return }
        GhosttyBridge.perform("navigate_search:previous", on: view)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        if let diff = keyDiffWindow { return diff.findSelection() }
        guard let view = sessions.selected?.view else { return }
        GhosttyBridge.perform("search_selection", on: view)
    }

    // MARK: Split actions
    //
    // These ask libghostty rather than editing the pane tree directly, so the
    // menu and ghostty's own keybind for the same thing (cmd-D and friends,
    // which the core claims before the menu ever sees them) meet on one path:
    // the core sends its action back and `GhosttyBridge` applies it. The core
    // also decides when an action is performable - `goto_split` on an unsplit
    // session does nothing - which is why these don't guard on that here.

    @objc func splitPaneRight(_ sender: Any?) { split(GHOSTTY_SPLIT_DIRECTION_RIGHT) }
    @objc func splitPaneDown(_ sender: Any?) { split(GHOSTTY_SPLIT_DIRECTION_DOWN) }
    @objc func nextPane(_ sender: Any?) { moveFocus(.next) }
    @objc func previousPane(_ sender: Any?) { moveFocus(.previous) }

    @objc func zoomPane(_ sender: Any?) {
        guard let surface = sessions.selected?.view.surface else { return }
        ghostty.splitToggleZoom(surface: surface)
    }

    @objc func equalizePanes(_ sender: Any?) {
        guard let surface = sessions.selected?.view.surface else { return }
        ghostty.splitEqualize(surface: surface)
    }

    private func split(_ direction: ghostty_action_split_direction_e) {
        guard let surface = sessions.selected?.view.surface else { return }
        ghostty.split(surface: surface, direction: direction)
    }

    private func moveFocus(_ direction: Ghostty.SplitFocusDirection) {
        guard let surface = sessions.selected?.view.surface else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
    }
}
