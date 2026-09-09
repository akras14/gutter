import AppKit
import GhosttyKit

/// The single libghostty <-> app boundary. Every notification name, ghostty
/// action enum, and surface<->session lookup lives here; the rest of the app
/// speaks only "sessions" and "windows". When updating ghostty, this is the
/// file to audit for API drift.
final class GhosttyBridge {
    private let sessions: SessionManager
    private let ghostty: Ghostty.App

    init(sessions: SessionManager, ghostty: Ghostty.App) {
        self.sessions = sessions
        self.ghostty = ghostty

        let nc = NotificationCenter.default
        // One pane, not the whole session: closing the last pane is what
        // removes the sidebar row (see SessionManager.closePane). This is
        // ghostty's own cmd-w (close_surface); alt-cmd-w is close_tab below.
        nc.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main) {
            [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            self?.sessions.closePane(view)
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
            self?.sessions.newSession(config: config)
        }
        nc.addObserver(forName: .ghosttyCloseTab, object: nil, queue: .main) { [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let session = self.sessions.session(for: view) else { return }
            self.sessions.close(session)
        }
        nc.addObserver(forName: Ghostty.Notification.ghosttyGotoTab, object: nil, queue: .main) {
            [weak self] note in
            guard let self,
                  let any = note.userInfo?[Ghostty.Notification.GotoTabKey],
                  let tab = any as? ghostty_action_goto_tab_e else { return }
            let raw = tab.rawValue
            if raw > 0 {
                self.sessions.select(index: Int(raw) - 1)
            } else if raw == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                self.sessions.cycle(-1)
            } else if raw == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                self.sessions.cycle(1)
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
            self.sessions.split(view, direction: direction, config: config)
        }
        nc.addObserver(forName: Ghostty.Notification.ghosttyFocusSplit, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let direction = note.userInfo?[Ghostty.Notification.SplitDirectionKey]
                    as? Ghostty.SplitFocusDirection else { return }
            self.sessions.movePaneFocus(from: view, direction: direction)
        }
        nc.addObserver(forName: Ghostty.Notification.didResizeSplit, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let direction = note.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey]
                    as? Ghostty.SplitResizeDirection,
                  let amount = note.userInfo?[Ghostty.Notification.ResizeSplitAmountKey]
                    as? UInt16 else { return }
            self.sessions.resize(view, direction: direction, amount: amount)
        }
        nc.addObserver(forName: Ghostty.Notification.didEqualizeSplits, object: nil, queue: .main) {
            [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            self?.sessions.equalize(view)
        }
        nc.addObserver(forName: Ghostty.Notification.didToggleSplitZoom, object: nil, queue: .main) {
            [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            self?.sessions.toggleZoom(view)
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

    /// What libghostty hands a new tab opened from `view`: working directory,
    /// font size, and whatever else the `*-inherit-*` config keys turn on.
    /// This is the same call ghostty's own app makes for its `new_tab` action,
    /// so the user's config decides what carries over - not this file.
    static func inheritedConfig(from view: Ghostty.SurfaceView) -> Ghostty.SurfaceConfiguration? {
        guard let surface = view.surface else { return nil }
        return Ghostty.SurfaceConfiguration(
            from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_TAB))
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
