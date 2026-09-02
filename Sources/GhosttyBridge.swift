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
        nc.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let session = self.sessions.session(for: view) else { return }
            self.sessions.remove(session)
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

        // Ghostty's toggle_fullscreen action -> native fullscreen on the surface's window.
        nc.addObserver(forName: Ghostty.Notification.ghosttyToggleFullscreen, object: nil, queue: .main) { note in
            (note.object as? Ghostty.SurfaceView)?.window?.toggleFullScreen(nil)
        }
    }
}

extension GhosttyBridge {
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
