import AppKit
import Combine
import GhosttyKit

/// One terminal session: a live SurfaceView plus sidebar display state.
final class Session {
    let id: UUID
    let view: Ghostty.SurfaceView
    var title: String = ""
    var hasActivity: Bool = false

    fileprivate init(view: Ghostty.SurfaceView) {
        self.id = view.id
        self.view = view
    }
}

/// Owns the list of terminal sessions and which one is selected.
final class SessionManager {
    private let ghostty: Ghostty.App

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
    }

    private(set) var sessions: [Session] = []
    private(set) var selected: Session?

    var onListChanged: (() -> Void)?
    var onSelectionChanged: ((Session?) -> Void)?
    var onEmpty: (() -> Void)?

    private var cancellables: [UUID: AnyCancellable] = [:]

    func surface(for uuid: UUID) -> Ghostty.SurfaceView? {
        sessions.first { $0.view.id == uuid }?.view
    }

    func session(for view: Ghostty.SurfaceView) -> Session? {
        sessions.first { $0.view === view }
    }

    @discardableResult
    func newSession() -> Session? {
        guard let app = ghostty.app else { return nil }
        let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: nil)
        let session = Session(view: view)
        sessions.append(session)

        // Shell-driven title (SurfaceView coalesces updates internally).
        let titleSub = view.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                session.title = title
                self?.onListChanged?()
            }

        // Bell/activity: dot on any tab that isn't the selected one.
        let bellSub = NotificationCenter.default.publisher(for: .ghosttyBellDidRing)
            .filter { ($0.object as? Ghostty.SurfaceView) === view }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.sessions.contains(where: { $0 === session }) else { return }
                guard session !== self.selected else { return }
                session.hasActivity = true
                self.onListChanged?()
            }

        cancellables[session.id] = AnyCancellable {
            titleSub.cancel()
            bellSub.cancel()
        }

        select(session)
        return session
    }

    func select(_ session: Session?) {
        guard session !== selected else { return }
        selected = session
        session?.hasActivity = false
        onSelectionChanged?(session)
        onListChanged?()
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index])
    }

    func cycle(_ direction: Int) {
        guard let current = selected,
              let idx = sessions.firstIndex(where: { $0 === current }),
              sessions.count > 1 else { return }
        let next = (idx + direction + sessions.count) % sessions.count
        select(sessions[next])
    }

    func close(_ session: Session) {
        if let surface = session.view.surface {
            ghostty.requestClose(surface: surface)
        } else {
            remove(session)
        }
    }

    func closeSelected() {
        guard let selected else { return }
        close(selected)
    }

    func remove(_ session: Session) {
        cancellables[session.id] = nil
        session.view.removeFromSuperview()

        if let idx = sessions.firstIndex(where: { $0 === session }) {
            sessions.remove(at: idx)
            if selected === session {
                selected = nil
                let next = sessions.indices.contains(idx) ? sessions[idx] : sessions.last
                select(next)
            }
        }

        onListChanged?()

        if sessions.isEmpty {
            onEmpty?()
        }
    }
}
