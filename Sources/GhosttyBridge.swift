import AppKit
import GhosttyKit

/// The single libghostty <-> app boundary. Every notification name, ghostty
/// action enum, and surface<->session lookup lives here; the rest of the app
/// speaks only "sessions" and "windows". When updating ghostty, this is the
/// file to audit for API drift.
///
/// One bridge for the whole app, however many windows are open: libghostty
/// posts to the default NotificationCenter, so an observer per window would see
/// every other window's actions too. The surface in the payload is what says
/// which window an action belongs to - `sessions(of:)` below - and an action
/// with no surface (libghostty's app-target variants) falls to the front
/// window.
final class GhosttyBridge {
    private unowned let app: AppDelegate
    private let ghostty: Ghostty.App

    /// The sessions of the window holding this surface. nil once the surface
    /// has been closed, which is what makes every observer below a no-op for a
    /// surface that is on its way out.
    private func sessions(of view: Ghostty.SurfaceView) -> SessionManager? {
        app.window(owning: view)?.sessions
    }

    /// Same, from a notification: the surface it fired on, or - for an
    /// app-target action, which carries none - the front window.
    private func sessions(for note: Notification) -> SessionManager {
        guard let view = note.object as? Ghostty.SurfaceView else { return app.sessions }
        return sessions(of: view) ?? app.sessions
    }

    init(app: AppDelegate, ghostty: Ghostty.App) {
        self.app = app
        self.ghostty = ghostty

        let nc = NotificationCenter.default
        // One pane, not the whole session: closing the last pane is what
        // removes the sidebar row (see SessionManager.closePane). This is
        // ghostty's own cmd-w (close_surface); alt-cmd-w is close_tab below.
        nc.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main) {
            [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            self?.sessions(of: view)?.closePane(view)
        }

        // Ghostty's own keybinds (cmd-t/cmd-w etc.) are consumed by the core and
        // emitted as app actions; wire them to the session manager so the user's
        // configured keybinds work as-is.
        nc.addObserver(forName: Ghostty.Notification.ghosttyNewTab, object: nil, queue: .main) {
            [weak self] note in
            // The payload is the config libghostty derived from the surface the
            // keybind fired on, and the new tab's working directory rides in it.
            // Dropping it opened every session in the home directory instead.
            let config = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
                as? Ghostty.SurfaceConfiguration
            // The new tab joins the window the keybind fired in, not whichever
            // window happens to be in front.
            self?.sessions(for: note).newSession(config: config)
        }

        // ⌘N. The core's own macOS default is `super+n=new_window`, so with a
        // surface focused the key never reaches the menu bar - this is the
        // path it takes instead, the same shape as ⌘T above. The payload is
        // the window-context inherited config, so the new window's first
        // session starts where the old one was.
        nc.addObserver(forName: Ghostty.Notification.ghosttyNewWindow, object: nil, queue: .main) {
            [weak self] note in
            let config = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
                as? Ghostty.SurfaceConfiguration
            self?.app.openWindow(config: config)
        }

        // ⇧⌘W (the core's `close_window`). Closes the whole window the surface
        // is in, sessions and all - `close_surface` is ⌘W and `close_tab` is
        // ⌥⌘W. performClose, so the window's own close path runs.
        nc.addObserver(forName: .ghosttyCloseWindow, object: nil, queue: .main) { [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            self?.app.window(owning: view)?.window?.performClose(nil)
        }
        nc.addObserver(forName: .ghosttyCloseTab, object: nil, queue: .main) { [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let sessions = self.sessions(of: view),
                  let session = sessions.session(for: view) else { return }
            sessions.close(session)
        }
        nc.addObserver(forName: Ghostty.Notification.ghosttyGotoTab, object: nil, queue: .main) {
            [weak self] note in
            guard let self,
                  let any = note.userInfo?[Ghostty.Notification.GotoTabKey],
                  let tab = any as? ghostty_action_goto_tab_e else { return }
            let raw = tab.rawValue
            let sessions = self.sessions(for: note)
            if raw > 0 {
                sessions.select(index: Int(raw) - 1)
            } else if raw == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                sessions.cycle(-1)
            } else if raw == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                sessions.cycle(1)
            }
        }

        // Splits. The keys are ghostty's own defaults - cmd-D, cmd-[/], the
        // opt-cmd and ctrl-cmd arrows - claimed by the core, so `main.swift`
        // overrides none of them. These turn the actions the core sends back
        // into changes to the session's pane tree.
        nc.addObserver(forName: Ghostty.Notification.ghosttyNewSplit, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let raw = note.userInfo?["direction"] as? ghostty_action_split_direction_e,
                  let direction = Self.newDirection(raw) else { return }
            // The payload carries the config libghostty derived from the
            // surface the split fired on, so the new pane inherits its
            // working directory - same deal as a new tab.
            let config = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
                as? Ghostty.SurfaceConfiguration
            self.sessions(of: view)?.split(view, direction: direction, config: config)
        }
        nc.addObserver(forName: Ghostty.Notification.ghosttyFocusSplit, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let direction = note.userInfo?[Ghostty.Notification.SplitDirectionKey]
                    as? Ghostty.SplitFocusDirection else { return }
            self.sessions(of: view)?.movePaneFocus(from: view, direction: direction)
        }
        nc.addObserver(forName: Ghostty.Notification.didResizeSplit, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let direction = note.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey]
                    as? Ghostty.SplitResizeDirection,
                  let amount = note.userInfo?[Ghostty.Notification.ResizeSplitAmountKey]
                    as? UInt16 else { return }
            self.sessions(of: view)?.resize(view, direction: direction, amount: amount)
        }
        nc.addObserver(forName: Ghostty.Notification.didEqualizeSplits, object: nil, queue: .main) {
            [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            self?.sessions(of: view)?.equalize(view)
        }
        nc.addObserver(forName: Ghostty.Notification.didToggleSplitZoom, object: nil, queue: .main) {
            [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            self?.sessions(of: view)?.toggleZoom(view)
        }

        // Ghostty's toggle_fullscreen action -> native fullscreen on the surface's window.
        nc.addObserver(forName: Ghostty.Notification.ghosttyToggleFullscreen, object: nil, queue: .main) { note in
            (note.object as? Ghostty.SurfaceView)?.window?.toggleFullScreen(nil)
        }
    }
}

extension GhosttyBridge {
    private static func newDirection(
        _ direction: ghostty_action_split_direction_e
    ) -> SplitTree<Ghostty.SurfaceView>.NewDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    /// What libghostty hands a new tab - or window - opened from `view`:
    /// working directory, font size, and whatever else the `*-inherit-*` config
    /// keys turn on. This is the same call ghostty's own app makes for its
    /// `new_tab` / `new_window` actions, so the user's config decides what
    /// carries over - not this file. The context is why: ghostty has separate
    /// `window-inherit-working-directory` and `tab-inherit-working-directory`
    /// keys, and passing the wrong one here would quietly ignore whichever the
    /// user set.
    static func inheritedConfig(
        from view: Ghostty.SurfaceView,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_TAB
    ) -> Ghostty.SurfaceConfiguration? {
        guard let surface = view.surface else { return nil }
        return Ghostty.SurfaceConfiguration(
            from: ghostty_surface_inherited_config(surface, context))
    }

    /// Fire one of ghostty's named keybind actions against a surface.
    ///
    /// libghostty exposes no typed C API for most features - search included
    /// (`ghostty.h` has the `search_*` *actions* it sends back, but no
    /// `ghostty_surface_search_*` to call). The generic binding-action entry
    /// point is the only way in, so the action name is the API.
    @discardableResult
    static func perform(_ action: String, on view: Ghostty.SurfaceView) -> Bool {
        guard let surface = view.surface else { return false }
        let ok = ghostty_surface_binding_action(
            surface, action, UInt(action.lengthOfBytes(using: .utf8)))
        if !ok {
            AppDelegate.logger.warning("action failed action=\(action)")
        }
        return ok
    }
}
