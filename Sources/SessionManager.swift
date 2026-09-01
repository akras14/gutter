import AppKit
import Combine
import GhosttyKit

/// One terminal session: a live SurfaceView plus sidebar display state.
final class Session {
    let id: UUID
    let view: Ghostty.SurfaceView
    /// What the shell reports. Keeps updating even while a custom title is set,
    /// so clearing the custom one falls back to something current.
    var title: String = ""
    /// Set by the user via rename; wins over the shell's title until cleared.
    var customTitle: String?
    var hasActivity: Bool = false
    /// Working directory, from libghostty's pwd action. nil until shell
    /// integration reports one, so some shells never fill it in.
    var pwd: String?
    /// `pwd`'s last component, or "~" for the home directory itself.
    var folder: String?
    /// Branch at `pwd`. nil outside a repo or on a detached HEAD.
    var branch: String?

    var displayTitle: String { customTitle ?? title }

    /// Folder plus branch: the stable identity of a session, as opposed to the
    /// title, which Claude Code and the shell both rewrite constantly.
    var location: String {
        guard let folder else { return "" }
        guard let branch else { return folder }
        return "\(folder) ⎇ \(branch)"
    }

    /// Top line: the name the user gave the session, else where it is, else
    /// whatever the shell calls itself.
    var primaryLine: String {
        if let customTitle { return customTitle }
        return location.isEmpty ? title : location
    }

    /// Bottom line: the live title under a stable top line, or the location
    /// under a name the user chose. Empty when it would only repeat the top
    /// line - a one-line row is better than a row that says it twice.
    var secondaryLine: String {
        let secondary = customTitle == nil ? title : location
        if secondary == primaryLine || secondary == folder { return "" }
        return secondary
    }

    /// Pending debounced branch check. See `SessionManager.scheduleBranchCheck`.
    fileprivate var branchCheck: DispatchWorkItem?

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
                // A retitle means the shell ran something, which is the only
                // hint we get that the branch may have moved.
                self?.scheduleBranchCheck(session)
            }

        // Working directory, for the sidebar's folder + branch line.
        let pwdSub = view.$pwd
            .receive(on: RunLoop.main)
            .sink { [weak self] pwd in
                self?.updateLocation(session, pwd: pwd)
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
            pwdSub.cancel()
            bellSub.cancel()
        }

        select(session)
        return session
    }

    /// The folder is free; the branch costs a git process, so it only runs when
    /// the directory actually changed, and off the main thread.
    private func updateLocation(_ session: Session, pwd: String?) {
        guard session.pwd != pwd else { return }
        session.pwd = pwd
        session.folder = pwd.map { $0 == NSHomeDirectory() ? "~" : ($0 as NSString).lastPathComponent }
        session.branch = nil
        onListChanged?()
        checkBranch(session)
    }

    /// `git switch` moves the branch without moving the directory, so pwd
    /// alone would leave the sidebar showing the old branch forever. The shell
    /// redraws its prompt right after, which retitles the surface - that's the
    /// signal. Debounced, because titles arrive in bursts (a command starting,
    /// then the prompt) and each check costs a git process. Kept short: the
    /// vendored `setTitle` already sits on the event for 75ms, and past about
    /// 200ms the sidebar visibly lags the `git switch` that caused it.
    private func scheduleBranchCheck(_ session: Session) {
        session.branchCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkBranch(session) }
        session.branchCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func checkBranch(_ session: Session) {
        session.branchCheck?.cancel()
        guard let pwd = session.pwd else { return }
        DispatchQueue.global(qos: .utility).async {
            let branch = Self.branch(in: pwd)
            DispatchQueue.main.async { [weak self] in
                guard let self, session.pwd == pwd, session.branch != branch,
                      self.sessions.contains(where: { $0 === session }) else { return }
                session.branch = branch
                self.onListChanged?()
            }
        }
    }

    private static func branch(in directory: String) -> String? {
        guard let (output, status) = GitDiff.run(["symbolic-ref", "--short", "-q", "HEAD"], in: directory),
              status == 0 else { return nil }
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// An empty or blank name clears the override and hands the row back to
    /// the shell's own title.
    func rename(_ session: Session, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customTitle = trimmed.isEmpty ? nil : trimmed
        onListChanged?()
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
        session.branchCheck?.cancel()
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
