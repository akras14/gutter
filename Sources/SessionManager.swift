import AppKit
import Combine
import GhosttyKit

/// One pane inside a session: a live surface plus the state that hangs off it.
///
/// All of this used to sit on `Session`, back when a session was exactly one
/// surface. It moved down here when sessions grew a tree of panes: every signal
/// libghostty reports is per-surface, and `Session` folds them into the single
/// answer a sidebar row needs.
final class Pane {
    let view: Ghostty.SurfaceView

    /// What the shell reports. Keeps updating even while a custom title is set,
    /// so clearing the custom one falls back to something current.
    var title: String = ""

    /// Working directory, from libghostty's pwd action. nil until shell
    /// integration reports one, so some shells never fill it in.
    var pwd: String?
    /// `pwd`'s last component, or "~" for the home directory itself.
    var folder: String?
    /// Branch at `pwd`. nil outside a repo or on a detached HEAD.
    var branch: String?

    /// A bell rang here while the pane wasn't being looked at.
    var hasActivity: Bool = false

    /// True while the surface carries an OSC 9;4 progress report - the ConEmu
    /// sequence Windows Terminal, iTerm2 and ghostty all read as "working".
    /// Set from the surface's progressReport publisher.
    var isWorking: Bool = false

    /// Set on the working -> idle edge of a progress report. Serves the same
    /// purpose as Claude Code's "✳" title below: the pane just handed itself
    /// back to the user.
    var workFinished = false

    /// Claude Code prefixes the terminal title with a status glyph: "✳" when it
    /// hands the session back - finished, or asking something - and a spinner
    /// while it is still working. The two cases the glyph covers aren't
    /// distinguishable from the title, but both mean the same thing to the
    /// sidebar: this pane is waiting on the user. Anything else, a plain shell
    /// included, never lights the dot. `workFinished` means the same thing for
    /// tools that speak OSC 9;4.
    var isReady: Bool {
        title.trimmingCharacters(in: .whitespaces).hasPrefix("✳") || workFinished
    }

    /// True once the user has looked at this pane while it was ready. The glyph
    /// stays in the title for as long as Claude Code is waiting, so without this
    /// the dot would come back the moment the user switched away from a pane
    /// they had just read. Re-arms when the pane goes back to work: the next
    /// hand-off is news again.
    ///
    /// Per pane, not per session: a pane hidden behind a zoom hasn't been seen
    /// even though its session is selected.
    var readySeen = false

    /// Something happened in this pane that the user has not seen yet.
    var needsAttention: Bool { hasActivity || (isReady && !readySeen) }

    /// Pending debounced branch check. See `SessionManager.scheduleBranchCheck`.
    var branchCheck: DispatchWorkItem?

    /// Last occlusion state handed to libghostty. See
    /// `SessionManager.syncOcclusion`. nil until the first sync, so the first
    /// one always sends.
    var rendererVisible: Bool?

    init(view: Ghostty.SurfaceView) {
        self.view = view
    }
}

/// One terminal session: a tree of panes plus sidebar display state. One
/// session is one sidebar row, however many panes it holds.
final class Session {
    /// The panes, as a tree. `SplitTree` is immutable-with-copies, so every
    /// structural change is an assignment - `session.tree = session.tree.inserting(...)`.
    var tree: SplitTree<Ghostty.SurfaceView>

    /// One Pane per leaf of `tree`, in no particular order.
    private(set) var panes: [Pane]

    /// The pane that has, or last had, focus. Drives the row's title and
    /// location, and is where session-wide actions (find, git diff) land.
    var focusedPane: Pane

    /// The focused surface. Named `view` because that is what a session was
    /// before panes: every existing call site that says `session.view` wants
    /// the pane the user is looking at.
    var view: Ghostty.SurfaceView { focusedPane.view }

    /// Set by the user via rename; wins over the shell's title until cleared.
    var customTitle: String?

    init(pane: Pane) {
        self.tree = SplitTree(view: pane.view)
        self.panes = [pane]
        self.focusedPane = pane
    }

    func pane(for view: Ghostty.SurfaceView) -> Pane? {
        panes.first { $0.view === view }
    }

    func add(_ pane: Pane) {
        panes.append(pane)
    }

    func drop(_ pane: Pane) {
        panes.removeAll { $0 === pane }
    }

    // MARK: The folds
    //
    // Each signal below is per-pane. A sidebar row shows one value, so each one
    // folds a different way, and the difference matters: taking the focused
    // pane's title keeps the row from flickering between panes, while OR-ing
    // attention is what makes an agent handing back in a background pane light
    // the dot at all.

    /// The focused pane's, so the row doesn't flicker between panes.
    var title: String { focusedPane.title }
    var pwd: String? { focusedPane.pwd }
    var folder: String? { focusedPane.folder }
    var branch: String? { focusedPane.branch }

    /// OR over panes: any pane working spins the row.
    var isWorking: Bool { panes.contains(where: \.isWorking) }

    /// OR over panes. Without this an agent handing back in a pane you are not
    /// looking at would never light the dot.
    var needsAttention: Bool { panes.contains(where: \.needsAttention) }

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
}

/// Owns the list of terminal sessions, which one is selected, and the pane tree
/// inside each.
///
/// One per window, not one per app: a window is a whole independent sidebar of
/// sessions. Nothing here knows about other windows - `AppDelegate` owns them
/// and `GhosttyBridge` routes libghostty's app-wide notifications to the right
/// one by surface.
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
            self.markVisiblePanesSeen(selected)
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

    /// Whether this manager's window is on screen. One of the three parts of
    /// "is anyone looking at this pane" - see `isVisible` and `syncOcclusion`.
    private var windowVisible = true

    /// The size of the terminal area, reported by the container on layout.
    /// Only `resize` needs it: converting the core's "grow by N pixels" into a
    /// split ratio needs to know what the tree is being laid out in.
    var terminalBounds: CGRect = .zero

    var onListChanged: (() -> Void)?
    var onSelectionChanged: ((Session?) -> Void)?
    /// A session's pane tree changed shape. The container re-renders it.
    var onTreeChanged: ((Session) -> Void)?
    var onEmpty: (() -> Void)?

    /// Keyed by surface, not session: every pane has its own subscriptions.
    private var cancellables: [UUID: AnyCancellable] = [:]

    func surface(for uuid: UUID) -> Ghostty.SurfaceView? {
        for session in sessions {
            if let pane = session.panes.first(where: { $0.view.id == uuid }) { return pane.view }
        }
        return nil
    }

    func session(for view: Ghostty.SurfaceView) -> Session? {
        sessions.first { $0.pane(for: view) != nil }
    }

    // MARK: Sessions

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
        guard let pane = makePane(config: config) else { return nil }
        let session = Session(pane: pane)
        sessions.append(session)
        cancellables[pane.view.id] = subscribe(pane, in: session)
        syncOcclusion()

        if selectNew {
            select(session)
        } else {
            onListChanged?()
        }
        return session
    }

    private func makePane(config: Ghostty.SurfaceConfiguration?) -> Pane? {
        guard let app = ghostty.app else { return nil }
        return Pane(view: Ghostty.SurfaceView(app, baseConfig: config, uuid: nil))
    }

    /// Every per-surface signal the sidebar reads, for one pane. Cancelling the
    /// returned token cancels all of them.
    private func subscribe(_ pane: Pane, in session: Session) -> AnyCancellable {
        let view = pane.view

        /// A pane whose session or self has since been closed must not write
        /// back into the sidebar.
        func live() -> Bool {
            sessions.contains { $0 === session } && session.pane(for: view) != nil
        }

        // Shell-driven title (SurfaceView coalesces updates internally).
        let titleSub = view.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                guard let self, live() else { return }
                pane.title = title
                self.updateReadySeen(pane, in: session)
                self.onListChanged?()
                // A retitle means the shell ran something, which is the only
                // hint we get that the branch may have moved.
                self.scheduleBranchCheck(pane)
            }

        // Working directory, for the sidebar's folder + branch line.
        let pwdSub = view.$pwd
            .receive(on: RunLoop.main)
            .sink { [weak self] pwd in
                guard let self, live() else { return }
                self.updateLocation(pane, pwd: pwd)
            }

        // Bell/activity: dot on any pane that isn't being looked at. A pane
        // hidden behind a zoom counts as not looked at, even in the selected
        // session.
        let bellSub = NotificationCenter.default.publisher(for: .ghosttyBellDidRing)
            .filter { ($0.object as? Ghostty.SurfaceView) === view }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, live() else { return }
                guard !self.isVisible(pane, in: session) else { return }
                pane.hasActivity = true
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
                guard let self, live() else { return }
                let state = report?.state
                let working = state == .set || state == .indeterminate
                let finished = !working
                // A .pause can arrive while already idle (the tool never
                // reported work), so the dot has to key off both flags.
                guard working != pane.isWorking || finished != pane.workFinished
                else { return }
                pane.isWorking = working
                pane.workFinished = finished
                self.updateReadySeen(pane, in: session)
                self.onListChanged?()
            }

        // Which pane the user is actually in, clicks included. The surface
        // stamps focusInstant in `focusDidChange` every time it gains focus,
        // and unlike `focused` it is @Published - so this is the vendored
        // signal for "this pane took focus", and Gutter tracks no responders
        // of its own.
        let focusSub = view.$focusInstant
            .receive(on: RunLoop.main)
            .sink { [weak self] instant in
                guard let self, instant != nil, live() else { return }
                self.focusPane(view)
            }

        return AnyCancellable {
            titleSub.cancel()
            pwdSub.cancel()
            bellSub.cancel()
            progressSub.cancel()
            focusSub.cancel()
        }
    }

    // MARK: Panes

    /// Split `view`'s pane, putting a new surface beside it. `config` is what
    /// libghostty derived from the surface the split fired on, so the new pane
    /// inherits its working directory.
    func split(_ view: Ghostty.SurfaceView,
               direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
               config: Ghostty.SurfaceConfiguration?) {
        guard let session = session(for: view),
              let pane = makePane(config: config),
              let tree = try? session.tree.inserting(view: pane.view, at: view, direction: direction)
        else { return }

        session.tree = tree
        session.add(pane)
        session.focusedPane = pane
        cancellables[pane.view.id] = subscribe(pane, in: session)
        treeChanged(session)
        onListChanged?()
        Ghostty.moveFocus(to: pane.view, from: view)
    }

    /// Close one pane. The last pane closes the session - that is what makes a
    /// sidebar row disappear.
    func closePane(_ view: Ghostty.SurfaceView) {
        guard let session = session(for: view), let pane = session.pane(for: view) else { return }
        guard session.panes.count > 1 else {
            remove(session)
            return
        }
        guard let node = session.tree.root?.node(view: view) else { return }

        // Pick the survivor before the node goes away.
        let survivor = session.tree.focusTarget(for: .next, from: node)
        session.tree = session.tree.removing(node)
        release(pane)
        session.drop(pane)

        if session.focusedPane === pane,
           let survivor, let next = session.pane(for: survivor) {
            session.focusedPane = next
        }

        treeChanged(session)
        onListChanged?()
        if session === selected { Ghostty.moveFocus(to: session.view) }
    }

    /// The pane took focus. Drives the row's title and clears what the user is
    /// now looking at.
    func focusPane(_ view: Ghostty.SurfaceView) {
        guard let session = session(for: view), let pane = session.pane(for: view),
              session.focusedPane !== pane else { return }
        session.focusedPane = pane
        markVisiblePanesSeen(session)
        onListChanged?()
    }

    /// Spatial or ordinal focus movement, from the core's `goto_split`.
    func movePaneFocus(from view: Ghostty.SurfaceView, direction: Ghostty.SplitFocusDirection) {
        guard let session = session(for: view),
              let node = session.tree.root?.node(view: view),
              let target = session.tree.focusTarget(
                for: direction.toSplitTreeFocusDirection(), from: node)
        else { return }
        focusPane(target)
        Ghostty.moveFocus(to: target, from: view)
    }

    /// Zoom is a property of the tree: one node takes the whole area and the
    /// rest stop rendering (see `syncOcclusion`).
    func toggleZoom(_ view: Ghostty.SurfaceView) {
        guard let session = session(for: view),
              let node = session.tree.root?.node(view: view) else { return }
        session.tree = .init(root: session.tree.root,
                             zoomed: session.tree.zoomed == nil ? node : nil)
        treeChanged(session)
        onListChanged?()
    }

    func equalize(_ view: Ghostty.SurfaceView) {
        guard let session = session(for: view) else { return }
        session.tree = session.tree.equalized()
        treeChanged(session)
    }

    /// Keyboard resize, from the core's `resize_split`. The tree needs the area
    /// it is laid out in to turn pixels into a ratio.
    func resize(_ view: Ghostty.SurfaceView,
                direction: Ghostty.SplitResizeDirection,
                amount: UInt16) {
        guard let session = session(for: view),
              let node = session.tree.root?.node(view: view) else { return }
        let spatial: SplitTree<Ghostty.SurfaceView>.Spatial.Direction = switch direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
        guard let tree = try? session.tree.resizing(
            node: node, by: amount, in: spatial, with: terminalBounds) else { return }
        session.tree = tree
        treeChanged(session)
    }

    /// Divider drag, from the SwiftUI `SplitView`'s ratio binding.
    func setRatio(_ session: Session, node: SplitTree<Ghostty.SurfaceView>.Node, to ratio: Double) {
        guard let tree = try? session.tree.replacing(node: node, with: node.resizing(to: ratio))
        else { return }
        session.tree = tree
        treeChanged(session)
    }

    /// Every structural change goes through here. Occlusion has to be resynced
    /// with the tree and not just on zoom: `inserting` and `resizing` both
    /// return a tree with the zoom cleared (`SplitTree.swift:129,332`), so a
    /// resize while zoomed silently makes hidden panes visible again.
    private func treeChanged(_ session: Session) {
        syncOcclusion()
        onTreeChanged?(session)
    }

    // MARK: Location

    /// The folder is free; the branch costs a git process, so it only runs when
    /// the directory actually changed, and off the main thread.
    private func updateLocation(_ pane: Pane, pwd: String?) {
        guard pane.pwd != pwd else { return }
        pane.pwd = pwd
        pane.folder = pwd.map { $0 == NSHomeDirectory() ? "~" : ($0 as NSString).lastPathComponent }
        pane.branch = nil
        onListChanged?()
        checkBranch(pane)
    }

    /// `git switch` moves the branch without moving the directory, so pwd
    /// alone would leave the sidebar showing the old branch forever. The shell
    /// redraws its prompt right after, which retitles the surface - that's the
    /// signal. Debounced, because titles arrive in bursts (a command starting,
    /// then the prompt) and each check costs a git process. Kept short: the
    /// vendored `setTitle` already sits on the event for 75ms, and past about
    /// 200ms the sidebar visibly lags the `git switch` that caused it.
    private func scheduleBranchCheck(_ pane: Pane) {
        pane.branchCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkBranch(pane) }
        pane.branchCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func checkBranch(_ pane: Pane) {
        pane.branchCheck?.cancel()
        guard let pwd = pane.pwd else { return }
        DispatchQueue.global(qos: .utility).async {
            let branch = Self.branch(in: pwd)
            DispatchQueue.main.async { [weak self] in
                guard let self, pane.pwd == pwd, pane.branch != branch,
                      self.session(for: pane.view) != nil else { return }
                pane.branch = branch
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

    // MARK: Selection and visibility

    func select(_ session: Session?) {
        guard session !== selected else { return }
        selected = session
        syncOcclusion()
        if let session { markVisiblePanesSeen(session) }
        onSelectionChanged?(session)
        onListChanged?()
    }

    /// The window went on or off screen - minimized, hidden, or fully covered.
    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        syncOcclusion()
        // Coming back into view reads the selected session, the same way
        // activating the app does. Both are needed: the two notifications
        // arrive in either order, and whichever is last is the one that finds
        // the pane actually visible.
        if visible, NSApp.isActive, let selected {
            markVisiblePanesSeen(selected)
            onListChanged?()
        }
    }

    /// Whether the user can actually see this pane: its window is on screen,
    /// its session is selected there, and no zoom is hiding it.
    ///
    /// The window half used to live only in `syncOcclusion`, because with one
    /// window "the app is active" was close enough to "you can see this" for
    /// the dot. With several it isn't: a covered window's selected session
    /// would have its hand-off marked as read on every app activation, and a
    /// bell in it would never light a dot at all.
    private func isVisible(_ pane: Pane, in session: Session) -> Bool {
        guard windowVisible, session === selected else { return false }
        guard let zoomed = session.tree.zoomed else { return true }
        return zoomed.leaves().contains { $0 === pane.view }
    }

    /// Tell libghostty which surfaces are actually being looked at: only panes
    /// of the selected session, only those a zoom isn't hiding, and only while
    /// the window is on screen.
    ///
    /// Without this, libghostty draws every surface it has, at full render
    /// thread QoS, forever - a background session with a busy agent in it
    /// paints frames into a layer that is not in any view hierarchy, and its
    /// window-sized Metal drawables stay resident because they keep being
    /// presented. Eleven sessions measured ~960MB of IOSurface that way. Panes
    /// multiply that, so a zoomed-out pane has to go dark too.
    ///
    /// ghostty's own shell makes this call from
    /// `BaseTerminalController.windowDidChangeOcclusionState`, which lives in
    /// its app target - `vendor.sh` copies the wrapper, not that, so nothing
    /// here made the call and every surface stayed "visible" (the core's
    /// default, `renderer/Thread.zig`).
    ///
    /// It pauses drawing and nothing else: the pty keeps running, the terminal
    /// keeps updating, the sidebar keeps lighting its dot, and the core queues
    /// a redraw the instant a surface becomes visible again. A session that is
    /// never selected still works exactly as it did.
    private func syncOcclusion() {
        for session in sessions {
            for pane in session.panes {
                let visible = isVisible(pane, in: session)
                guard pane.rendererVisible != visible,
                      let surface = pane.view.surface else { continue }
                ghostty_surface_set_occlusion(surface, visible)
                pane.rendererVisible = visible
            }
        }
    }

    /// Looking at a pane marks its current ready state as read, and clears the
    /// bell. A pane that is no longer ready forgets it saw one, so the next
    /// hand-off lights the dot again.
    private func markVisiblePanesSeen(_ session: Session) {
        for pane in session.panes {
            if isVisible(pane, in: session) { pane.hasActivity = false }
            updateReadySeen(pane, in: session)
        }
    }

    private func updateReadySeen(_ pane: Pane, in session: Session) {
        if !pane.isReady {
            pane.readySeen = false
        } else if isVisible(pane, in: session), NSApp.isActive {
            pane.readySeen = true
        }
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index])
    }

    /// How many sessions are waiting on the user. The sidebar dot says which
    /// ones; this is the same signal counted, for the Dock badge that reads
    /// from outside the app.
    var attentionCount: Int {
        sessions.filter(\.needsAttention).count
    }

    /// The next session waiting on the user, forward from the selected one and
    /// wrapping. Never the selected one itself: `select` early-returns on the
    /// session already selected, so it would neither move nor clear a dot -
    /// and by the time this is reachable from the menu the app is active, which
    /// has already marked the selected session's hand-off as seen.
    var nextNeedingAttention: Session? {
        guard !sessions.isEmpty else { return nil }
        let start = selected.flatMap { current in sessions.firstIndex { $0 === current } } ?? -1
        for offset in 1...sessions.count {
            let candidate = sessions[(start + offset) % sessions.count]
            if candidate !== selected, candidate.needsAttention { return candidate }
        }
        return nil
    }

    /// Lands on the pane that actually wants you, not just the row: with panes
    /// the dot no longer tells you where in the row to look.
    ///
    /// Takes the session rather than finding it, because the walk crosses
    /// windows: in another window the session that wants you may be the one
    /// already selected there, which `nextNeedingAttention` skips by design.
    func selectForAttention(_ session: Session) {
        if let wanting = session.panes.first(where: \.needsAttention) {
            session.focusedPane = wanting
            // A zoom on some other pane would hide the one we just moved to.
            if let zoomed = session.tree.zoomed, !zoomed.leaves().contains(where: { $0 === wanting.view }) {
                session.tree = .init(root: session.tree.root, zoomed: nil)
                treeChanged(session)
            }
        }
        guard session !== selected else {
            // `select` early-returns on the session already selected, so the
            // pane move above still has to be shown and focused.
            markVisiblePanesSeen(session)
            onListChanged?()
            Ghostty.moveFocus(to: session.view)
            return
        }
        select(session)
    }

    func cycle(_ direction: Int) {
        guard let current = selected,
              let idx = sessions.firstIndex(where: { $0 === current }),
              sessions.count > 1 else { return }
        let next = (idx + direction + sessions.count) % sessions.count
        select(sessions[next])
    }

    // MARK: Closing

    /// Ask libghostty to close every pane. Each one confirms if it needs to and
    /// comes back through `closePane`; the last one removes the session.
    func close(_ session: Session) {
        let surfaces = session.panes.compactMap(\.view.surface)
        guard !surfaces.isEmpty else {
            remove(session)
            return
        }
        for surface in surfaces {
            ghostty.requestClose(surface: surface)
        }
    }

    func closeSelected() {
        guard let selected else { return }
        close(selected)
    }

    /// Drop a pane's subscriptions and take its surface out of the hierarchy.
    private func release(_ pane: Pane) {
        cancellables[pane.view.id] = nil
        pane.branchCheck?.cancel()
        pane.view.removeFromSuperview()
    }

    func remove(_ session: Session) {
        for pane in session.panes { release(pane) }

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
