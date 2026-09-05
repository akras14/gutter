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

    /// True while the surface carries an OSC 9;4 progress report - the ConEmu
    /// sequence Windows Terminal, iTerm2 and ghostty all read as "working".
    /// Set from the surface's progressReport publisher.
    var isWorking: Bool = false

    /// Set on the working -> idle edge of a progress report. Serves the same
    /// purpose as Claude Code's "✳" title below: the session just handed
    /// itself back to the user.
    fileprivate var workFinished = false

    /// Claude Code prefixes the terminal title with a status glyph: "✳" when it
    /// hands the session back - finished, or asking something - and a spinner
    /// while it is still working. The two cases the glyph covers aren't
    /// distinguishable from the title, but both mean the same thing to the
    /// sidebar: this session is waiting on the user. Anything else, a plain
    /// shell included, never lights the dot. `workFinished` means the same
    /// thing for tools that speak OSC 9;4.
    var isReady: Bool {
        title.trimmingCharacters(in: .whitespaces).hasPrefix("✳") || workFinished
    }

    /// True once the user has looked at this session while it was ready. The
    /// glyph stays in the title for as long as Claude Code is waiting, so
    /// without this the dot would come back the moment the user switched away
    /// from a tab they had just read. Re-arms when the session goes back to
    /// work: the next hand-off is news again.
    fileprivate var readySeen = false

    /// What the sidebar dot shows: something happened here that the user has
    /// not seen yet.
    var needsAttention: Bool { hasActivity || (isReady && !readySeen) }

    /// Folder plus branch: the stable identity of a session, as opposed to the
    /// title, which Claude Code and the shell both rewrite constantly.
    var location: String {
        guard let folder else { return "" }
        guard let branch else { return folder }
        return "\(folder) ⎇ \(branch)"
    }

    /// What the row calls this session when the user hasn't named it: the
    /// shell's own title, or where it is when there is no title yet. Also the
    /// placeholder in the rename field - clearing the name goes back to this.
    var autoTitle: String {
        title.isEmpty ? location : title
    }

    /// Top line: what to call the session. Bottom line: where it is. Fixed
    /// roles, so renaming replaces the top line instead of shuffling the two
    /// around; every row reads the same way whether or not it has a name.
    var primaryLine: String {
        customTitle ?? autoTitle
    }

    /// Empty when it would only repeat the top line - a one-line row is better
    /// than a row that says it twice.
    var secondaryLine: String {
        location == primaryLine ? "" : location
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

    /// A session that goes ready while Gutter is in the background hasn't been
    /// seen, even if it is the selected one - coming back to the app is what
    /// marks it read.
    private var activationObserver: Any?

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let selected = self.selected else { return }
            self.updateReadySeen(selected)
            self.onListChanged?()
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
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

    /// `config` is what the new session inherits from the one it was opened
    /// from - the working directory above all, plus whatever else ghostty's
    /// `*-inherit-*` config keys turn on. nil takes libghostty's defaults,
    /// which start the session in `working-directory` (home, normally).
    /// `select` false leaves the current session in front. A request fired
    /// off into a new tab has to run without stealing focus from whatever the
    /// user is in the middle of - that is the point of firing it off. The pty
    /// spawns in `SurfaceView.init` either way, so a session that is never
    /// shown still runs, at the 800x600 frame the view starts with.
    @discardableResult
    func newSession(config: Ghostty.SurfaceConfiguration? = nil, select selectNew: Bool = true) -> Session? {
        guard let app = ghostty.app else { return nil }
        let view = GutterSurfaceView(app, baseConfig: config, uuid: nil)
        let session = Session(view: view)
        sessions.append(session)

        // Shell-driven title (SurfaceView coalesces updates internally).
        let titleSub = view.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                session.title = title
                self?.updateReadySeen(session)
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

        // OSC 9;4 progress. Only .set and .indeterminate mean the tool is
        // working. .pause and .error are hand-offs, not work - opencode's
        // progress plugin sends .pause for "waiting for input", which is
        // precisely when the user is wanted - and so is a cleared report,
        // whether that's the tool's own "remove" or the vendored wrapper's
        // 15s expiry of an unrefreshed one. All of them light the dot rather
        // than spin: the progress equivalent of the "✳" title.
        let progressSub = view.$progressReport
            .receive(on: RunLoop.main)
            .sink { [weak self] report in
                guard let self, self.sessions.contains(where: { $0 === session }) else { return }
                let state = report?.state
                let working = state == .set || state == .indeterminate
                let finished = !working
                // A .pause can arrive while already idle (the tool never
                // reported work), so the dot has to key off both flags.
                guard working != session.isWorking || finished != session.workFinished
                else { return }
                session.isWorking = working
                session.workFinished = finished
                self.updateReadySeen(session)
                self.onListChanged?()
            }

        cancellables[session.id] = AnyCancellable {
            titleSub.cancel()
            pwdSub.cancel()
            bellSub.cancel()
            progressSub.cancel()
        }

        if selectNew {
            select(session)
        } else {
            onListChanged?()
        }
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

    /// Drag-reorder from the sidebar. `to` is an insertion point, so it can be
    /// one past the end and can sit on either side of the row being moved.
    func move(from: Int, to: Int) {
        guard sessions.indices.contains(from), to >= 0, to <= sessions.count else { return }
        let target = to > from ? to - 1 : to
        guard target != from else { return }
        let session = sessions.remove(at: from)
        sessions.insert(session, at: target)
        onListChanged?()
    }

    func select(_ session: Session?) {
        guard session !== selected else { return }
        selected = session
        session?.hasActivity = false
        if let session { updateReadySeen(session) }
        onSelectionChanged?(session)
        onListChanged?()
    }

    /// Visiting a tab marks its current ready state as read; a tab that is no
    /// longer ready forgets it saw one, so the next hand-off lights the dot.
    private func updateReadySeen(_ session: Session) {
        if !session.isReady {
            session.readySeen = false
        } else if session === selected, NSApp.isActive {
            session.readySeen = true
        }
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
