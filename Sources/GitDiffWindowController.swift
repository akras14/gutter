import AppKit

/// A side-by-side view of everything not yet committed in the selected
/// session's working directory: changed files on the left, HEAD and the
/// worktree in two aligned panes on the right.
///
/// The session's directory comes from `SurfaceView.pwd`, which libghostty only
/// knows when the shell reports it (OSC 7 / shell integration). Without it
/// there is nothing to run git in, so the window says so rather than guessing
/// a directory.
///
/// `GitDiff` does all the git work and the line alignment; this file is only
/// AppKit - a table, two text views, and the scroll sync that keeps them
/// locked together.
final class GitDiffWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                     NSWindowDelegate, NSSearchFieldDelegate {
    private let pathLabel = NSTextField(labelWithString: "")
    private let fileTable = NSTableView()
    private let leftView = NSTextView()
    private let rightView = NSTextView()
    private var leftScroll = NSScrollView()
    private var rightScroll = NSScrollView()
    private var splitVC: NSSplitViewController!
    private let mapView = DiffMapView()

    private var directory: String?
    private var changes: [GitDiff.FileChange] = []
    /// Which side of the toggle is on. Kept on the controller, so the window
    /// comes back on the comparison it was left on.
    private var base: GitDiff.Base = .uncommitted
    /// The rev `base` resolved to on the last load. Every file the panes read
    /// comes from this, so it is captured once per load rather than re-resolved
    /// per file - a branch moving mid-review would otherwise mix two bases.
    private var baseRev = "HEAD"
    private let baseToggle = NSSegmentedControl()
    /// The left pane's caption. Updated per load: the left pane is HEAD in
    /// uncommitted mode but the fork point in branch mode, and a caption stuck
    /// on "HEAD" is exactly the two-dot misreading the header works to avoid.
    private lazy var leftPaneLabel = paneTitle("HEAD")
    private lazy var rightPaneLabel = paneTitle("Working tree")
    /// Which ref branch mode compares against. Only shown in branch mode -
    /// there is nothing to pick when the base is HEAD.
    private let baseRefPopup = NSPopUpButton()
    /// Root of the repo on screen, and the key `baseRefByRepo` is stored under.
    /// nil until a load finds a repo, which is what the popup waits for.
    private var repoRoot: String?
    /// The picked base ref per repo root. Remembered because the answer is a
    /// property of the repo, not of a visit to it: a stacked branch keeps the
    /// same parent for as long as it is being worked on, and re-picking it on
    /// every open would make the picker worse than the inference it replaces.
    private var baseRefByRepo: [String: String] =
        UserDefaults.standard.dictionary(forKey: baseRefDefaultsKey) as? [String: String] ?? [:]
    private static let baseRefDefaultsKey = "Gutter Git Diff Base Refs"
    /// Kept across refreshes so a reload doesn't jump back to the first file.
    private var selectedPath: String?
    /// The directory the header's summary describes. A reload of the same one
    /// leaves the last summary up until the new one is ready, rather than
    /// flashing the bare path in between.
    private var labelledDirectory: String?
    /// Watches the repo on screen. Live only while the window is open: a hidden
    /// window has nothing to keep current, and the git call below shouldn't run
    /// for one.
    private lazy var watcher = RepoWatcher { [weak self] paths in
        self?.repoChanged(paths)
    }
    /// Set when something git cares about has changed since this was loaded.
    /// The window says so and stops there - see `markStale`.
    private var isStale = false
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    /// Bumped on every load; a result carrying a stale token is dropped, so a
    /// slow file can't overwrite the pane after the user picked another one.
    private var loadToken = 0
    /// Guards the two scroll observers against echoing each other forever.
    private var syncingScroll = false
    /// Row count and change blocks of the file on screen, for the map strip and
    /// the next/previous-change jumps.
    private var rowCount = 0
    private var blocks: [DiffMapView.Block] = []

    // Find. One bar per changes window, searching one pane at a time - the
    // way a diff question is usually asked: "where is this in the old file?"
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findCountLabel = NSTextField(labelWithString: "")
    /// The rows on screen. A find searches these rather than the rendered
    /// panes, whose lines also carry line numbers and padding a needle must not
    /// match - searching "12" would otherwise light every twelfth line number.
    private var shownRows: [GitDiff.Row] = []
    /// Where each row's text starts in each pane's text storage, in UTF-16
    /// units, so a match in a row's text maps back to a range on screen.
    private var leftBodyStarts: [Int] = []
    private var rightBodyStarts: [Int] = []
    private struct FindMatch {
        let row: Int
        /// Within the row's text on the searched side, not the pane's.
        let range: NSRange
    }
    /// The pane a find searches: the one last clicked into, or picked in the
    /// bar. Starts on the right - the worktree is the file being edited.
    private var findSide: Side = .right
    private let findSideToggle = NSSegmentedControl()
    /// Follows focus into the panes, so clicking one is how it becomes the
    /// searched one.
    private var responderObservation: NSKeyValueObservation?
    private var matches: [FindMatch] = []
    /// Nil until the user steps to one: opening a file with a query live
    /// lights the matches but leaves the reader at the top.
    private var currentMatch: Int?
    /// The query `matches` was built from, so an action that didn't change the
    /// text (Return, a repeat of the same keystroke) doesn't reset the stepping.
    private var searchedNeedle = ""

    // Meld's palette, roughly: red for what HEAD had, green for what the
    // worktree has, blue for a line that exists on both sides but changed.
    // Low alpha so the text stays readable in either appearance.
    private static let removedBG = NSColor.systemRed.withAlphaComponent(0.16)
    private static let addedBG = NSColor.systemGreen.withAlphaComponent(0.16)
    private static let changedBG = NSColor.systemBlue.withAlphaComponent(0.13)
    private static let intralineBG = NSColor.systemBlue.withAlphaComponent(0.30)
    private static let fillerBG = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
    // The map strip is a few points wide, so its marks need full strength to
    // read at all - the pane backgrounds above would vanish at that size.
    private static let mapRemoved = NSColor.systemRed.withAlphaComponent(0.85)
    private static let mapAdded = NSColor.systemGreen.withAlphaComponent(0.85)
    private static let mapChanged = NSColor.systemBlue.withAlphaComponent(0.85)
    // Find highlights sit over the diff colors, so they are yellow and orange:
    // the two hues the diff palette doesn't use.
    private static let matchBG = NSColor.systemYellow.withAlphaComponent(0.40)
    private static let currentMatchBG = NSColor.systemOrange.withAlphaComponent(0.70)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // Not "Uncommitted Changes" any more: the header toggle picks
        // between that and the whole branch, so the title has to cover both.
        window.title = "Changes"
        // The controller outlives the close - cmd-w hides this window and the
        // shortcut brings the same one back - so the window must not be
        // released out from under that reference.
        window.isReleasedWhenClosed = false
        self.init(window: window)

        pathLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        refreshButton.target = self
        refreshButton.action = #selector(reload(_:))
        refreshButton.bezelStyle = .rounded
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = [.command]
        refreshButton.toolTip = "Re-read the working tree (⌘R)"
        // Sized for the stale title up front, so the dot appearing doesn't
        // widen the button and shift the controls beside it.
        refreshButton.title = "Refresh •"
        refreshButton.widthAnchor.constraint(equalToConstant: refreshButton.fittingSize.width).isActive = true
        refreshButton.title = "Refresh"
        // windowWillClose stops the watcher; nothing else here needs a delegate.
        window.delegate = self

        let previous = navButton("chevron.up", "Previous Change (⌘[)", "[", #selector(previousChange(_:)))
        let next = navButton("chevron.down", "Next Change (⌘])", "]", #selector(nextChange(_:)))

        baseToggle.segmentStyle = .automatic
        baseToggle.trackingMode = .selectOne
        baseToggle.segmentCount = 2
        baseToggle.setLabel("Uncommitted", forSegment: 0)
        baseToggle.setLabel("Branch", forSegment: 1)
        baseToggle.setToolTip("Changes not yet committed", forSegment: 0)
        baseToggle.setToolTip("The merge base with a branch: everything a PR opened now would carry",
                              forSegment: 1)
        baseToggle.selectedSegment = 0
        baseToggle.target = self
        baseToggle.action = #selector(baseChanged(_:))

        baseRefPopup.target = self
        baseRefPopup.action = #selector(baseRefChanged(_:))
        baseRefPopup.toolTip = "Compare against the merge base with this branch"
        baseRefPopup.isHidden = true
        // A long ref name would otherwise stretch the popup across the header
        // and squeeze out the path label.
        baseRefPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true

        // The controls hang off the trailing edge and the summary takes what is
        // left. Packed after the summary instead, every control moved whenever
        // its text changed length - on every mode switch, refresh and file
        // count. The popup is the leftmost control for the same reason: it
        // comes and goes with branch mode and its width follows the ref name,
        // so it grows into the summary's room rather than pushing the toggle
        // out from under the click that showed it.
        let header = NSStackView()
        header.setViews([pathLabel], in: .leading)
        header.setViews([baseRefPopup, baseToggle, previous, next, refreshButton], in: .trailing)
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false
        // Pin the header's height and let the split view take every remaining
        // point. Without this the two have equal vertical hugging, the solver
        // gave the slack to the header, and the label floated in the middle of
        // a tall empty band with the panes pushed to the bottom of the window.
        header.heightAnchor.constraint(equalToConstant: 38).isActive = true
        header.setContentHuggingPriority(.required, for: .vertical)

        // NSSplitViewController, not a bare NSSplitView: it enforces each
        // side's minimum and maximum thickness. A plain split view divided its
        // subviews proportionally instead, which left the file list filling the
        // window and squeezed the two panes into a sliver at its edge - and it
        // ignored setPosition, called before the view had a frame to divide.
        let split = NSSplitViewController()
        let listItem = NSSplitViewItem(sidebarWithViewController: HostingViewController(makeFileList()))
        listItem.minimumThickness = 200
        listItem.maximumThickness = 520
        listItem.canCollapse = false
        split.addSplitViewItem(listItem)
        let panesItem = NSSplitViewItem(viewController: HostingViewController(makePanes()))
        panesItem.minimumThickness = 420
        split.addSplitViewItem(panesItem)
        split.splitView.autosaveName = "Gutter Git Diff Split"
        splitVC = split

        makeFindBar()
        // A vertical stack so the find bar takes no room while hidden: a stack
        // detaches hidden views, where a plain constraint would keep its band.
        let top = NSStackView(views: [header, findBar])
        top.orientation = .vertical
        top.spacing = 0
        top.translatesAutoresizingMaskIntoConstraints = false
        // NSStackView's own hugging, not setContentHuggingPriority: a stack
        // hugs its views at 250 by default, so the solver handed it all the
        // slack and the panes sank to the bottom of the window - the same
        // failure the header's height pin above exists to prevent.
        top.setHuggingPriority(.required, for: .vertical)

        let content = NSView()
        let container = HostingViewController(content)
        container.addChild(split)
        let body = split.view
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        content.addSubview(top)
        content.addSubview(body)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            top.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            findBar.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            body.topAnchor.constraint(equalTo: top.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentViewController = container
        // Setting contentViewController resizes the window to the content's
        // fitting height, and two scroll views fit into almost nothing - the
        // window came back a title bar tall. Restore the intended size after
        // the assignment, and keep the autosave name for last so a saved frame
        // wins over the default rather than being overwritten by it.
        window.contentMinSize = NSSize(width: 720, height: 360)
        let hasSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame Gutter Git Diff Window") != nil
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.setFrameAutosaveName("Gutter Git Diff Window")
        if !hasSavedFrame { window.center() }
    }

    // MARK: Layout

    private func makeFileList() -> NSView {
        fileTable.headerView = nil
        fileTable.style = .inset
        fileTable.rowHeight = 24
        fileTable.allowsEmptySelection = true
        fileTable.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.width = 280
        // The single column tracks the list's width, so a long path truncates
        // (head first, keeping the file name) instead of running off the edge.
        column.resizingMask = .autoresizingMask
        fileTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        fileTable.addTableColumn(column)
        fileTable.dataSource = self
        fileTable.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = fileTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Preferred, not fixed: the split view item's min/max thickness are the
        // hard limits, and this only decides where the divider starts out.
        let preferredWidth = scroll.widthAnchor.constraint(equalToConstant: 320)
        preferredWidth.priority = .defaultLow
        preferredWidth.isActive = true
        return scroll
    }

    private func makePanes() -> NSView {
        leftScroll = makePane(leftView)
        rightScroll = makePane(rightView)

        let left = stackedPane(title: leftPaneLabel, scroll: leftScroll)
        let right = stackedPane(title: rightPaneLabel, scroll: rightScroll)

        // The map strip sits where the divider would be: it is the divider,
        // plus every change in the file at a glance. Its top and bottom track
        // the scroll views, not the container, so a mark lines up with the row
        // it stands for rather than being offset by the pane titles.
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.onJump = { [weak self] fraction in self?.scrollPanes(toFraction: fraction) }

        let container = NSView()
        container.addSubview(left)
        container.addSubview(mapView)
        container.addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: leftScroll.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: leftScroll.bottomAnchor),
            mapView.widthAnchor.constraint(equalToConstant: DiffMapView.width),
            right.leadingAnchor.constraint(equalTo: mapView.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            right.topAnchor.constraint(equalTo: container.topAnchor),
            right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // Equal halves: the two sides always show the same rows, so a
            // draggable divider between them would only ever hide one of them.
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        return container
    }

    private func navButton(_ symbol: String, _ tip: String, _ key: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                              target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = tip
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = [.command]
        return button
    }

    private func paneTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        // The left caption is a ref name in branch mode, and a label resists
        // compression by default - a long one would widen both panes (they
        // are held equal) and push the file list's divider over.
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func stackedPane(title: NSTextField, scroll: NSScrollView) -> NSView {
        title.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, scroll])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return stack
    }

    private func makePane(_ textView: NSTextView) -> NSScrollView {
        textView.isEditable = false
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        // No wrapping: a wrapped line would take two rows on one side and one
        // on the other, and the two panes would stop lining up.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = textView
        // Layer-backed for the border that marks the pane a find searches.
        scroll.wantsLayer = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let minHeight = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        minHeight.priority = .defaultLow
        minHeight.isActive = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(paneScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    /// Both panes scroll as one, the way meld's do: whichever clip view moved
    /// pushes its origin onto the other. `syncingScroll` stops the mirrored
    /// scroll from bouncing straight back.
    @objc private func paneScrolled(_ note: Notification) {
        guard !syncingScroll, let moved = note.object as? NSClipView else { return }
        let other: NSScrollView
        if moved === leftScroll.contentView {
            other = rightScroll
        } else if moved === rightScroll.contentView {
            other = leftScroll
        } else {
            return
        }
        let origin = moved.bounds.origin
        guard other.contentView.bounds.origin != origin else { return }
        syncingScroll = true
        other.contentView.scroll(to: origin)
        other.reflectScrolledClipView(other.contentView)
        syncingScroll = false
        updateMapViewport()
    }

    // MARK: Loading

    /// Show the window for `directory` (nil when the session's pwd is unknown).
    func present(directory: String?) {
        self.directory = directory
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload(nil)
    }

    /// ⌘W hides this window and the shortcut brings the same one back, so the
    /// watcher has to go down with it: nothing on screen to keep current, and
    /// no reason to run git for a window nobody has open. The next load starts
    /// it again.
    func windowWillClose(_ notification: Notification) {
        watcher.stop()
        markStale(false)
    }

    @objc private func baseChanged(_ sender: Any?) {
        let picked: GitDiff.Base = baseToggle.selectedSegment == 1 ? .branch : .uncommitted
        guard picked != base else { return }
        base = picked
        baseRefPopup.isHidden = picked != .branch
        reload(nil)
    }

    /// Picking a base is per repo and sticks. Nothing to do until a load has
    /// told us which repo we are in.
    @objc private func baseRefChanged(_ sender: Any?) {
        guard let repoRoot, let ref = baseRefPopup.titleOfSelectedItem,
              baseRefByRepo[repoRoot] != ref else { return }
        baseRefByRepo[repoRoot] = ref
        UserDefaults.standard.set(baseRefByRepo, forKey: Self.baseRefDefaultsKey)
        reload(nil)
    }

    @objc private func reload(_ sender: Any?) {
        markStale(false)
        guard let directory else {
            pathLabel.stringValue = "no directory"
            labelledDirectory = nil
            changes = []
            fileTable.reloadData()
            showNote("""
                Gutter doesn't know this session's working directory.

                It comes from the shell (ghostty's shell integration reports it \
                with OSC 7). Run a command in the tab, or enable shell \
                integration, then try again.
                """)
            return
        }

        if directory != labelledDirectory {
            pathLabel.stringValue = (directory as NSString).abbreviatingWithTildeInPath
            labelledDirectory = directory
        }
        window?.subtitle = (directory as NSString).lastPathComponent
        showNote("Loading...")

        loadToken += 1
        let token = loadToken
        let base = self.base
        // The remembered pick is keyed by repo root, which takes a git call to
        // learn, so the whole map goes along and the lookup happens once the
        // root is known. The window is reused across sessions, so the previous
        // directory's ref must not carry into a different repo.
        let remembered = baseRefByRepo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard FileManager.default.fileExists(atPath: directory) else {
                DispatchQueue.main.async {
                    self?.finishLoad(token, repo: nil, baseline: nil, changes: [],
                                     candidates: [], uncommitted: 0)
                }
                return
            }
            let repo = GitDiff.repo(at: directory)
            let preferred = repo.flatMap { remembered[$0.root] }
            let baseline = repo == nil
                ? nil
                : GitDiff.baseline(base, preferredRef: preferred, in: directory)
            let changes = baseline.map { GitDiff.changes(in: directory, since: $0.rev) } ?? []
            // The single way branch mode differs from GitHub's Files changed:
            // the panes read the worktree, so work that isn't committed is
            // folded in. Counting it lets the header own the difference
            // instead of leaving the file count quietly disagreeing with the
            // PR. Costs a second status call, so only where it can differ.
            var uncommitted = 0
            if base == .branch, !changes.isEmpty {
                let dirty = Set(GitDiff.changes(in: directory, since: "HEAD").map(\.path))
                uncommitted = changes.filter { dirty.contains($0.path) }.count
            }
            // Only branch mode has a base to pick, and listing every ref costs
            // a git call, so uncommitted mode doesn't pay for it.
            let candidates = repo != nil && base == .branch
                ? GitDiff.candidateRefs(in: directory)
                : []
            DispatchQueue.main.async {
                self?.finishLoad(token, repo: repo, baseline: baseline, changes: changes,
                                 candidates: candidates, uncommitted: uncommitted)
            }
        }
    }

    /// A batch of paths from the watcher. The window never reloads itself on
    /// one: a reload re-renders both panes from the top, so doing it while
    /// someone is reading would lose their place in a file that can be
    /// thousands of lines long - the whole-file panes make scroll position the
    /// thing you'd lose. It marks the button instead and leaves ⌘R the only
    /// thing that changes what is on screen.
    private func repoChanged(_ paths: [String]) {
        // Already lit: nothing to learn, and no reason to pay for another git
        // call while an agent writes.
        guard !isStale, let directory, window?.isVisible == true else { return }

        var refsMoved = false
        var candidates: [String] = []
        for path in paths {
            guard let git = path.range(of: "/.git/") else {
                if !path.hasSuffix("/.git") { candidates.append(path) }
                continue
            }
            // Inside .git, only what a commit or a checkout moves counts. The
            // index is the one to leave alone: git rewrites its stat cache
            // during the very `git diff` a load runs, so watching it would
            // relight the hint on every refresh.
            let inside = path[git.upperBound...]
            if inside.hasPrefix("logs/") || inside.hasPrefix("refs/")
                || inside == "HEAD" || inside == "packed-refs" {
                refsMoved = true
            }
        }

        // A commit, a checkout or a reset: the base moved under the panes,
        // which is the case that matters most - in uncommitted mode a commit
        // empties the diff outright.
        if refsMoved {
            markStale(true)
            return
        }
        guard !candidates.isEmpty else { return }
        // A batch this large is a checkout, a branch switch or a build; asking
        // git about each path would cost more than the answer is worth.
        guard candidates.count <= 64 else {
            markStale(true)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard GitDiff.containsUnignored(candidates, in: directory) else { return }
            DispatchQueue.main.async { self?.markStale(true) }
        }
    }

    /// The hint itself: a dot on the button that answers it. Deliberately
    /// quiet - the window is read while an agent works, so this has to be
    /// noticeable on the next glance without pulling the eye off the diff.
    private func markStale(_ stale: Bool) {
        guard stale != isStale else { return }
        isStale = stale
        refreshButton.title = stale ? "Refresh •" : "Refresh"
        refreshButton.toolTip = stale
            ? "The repo has changed since this was loaded - ⌘R to re-read it"
            : "Re-read the working tree (⌘R)"
    }

    private func finishLoad(_ token: Int, repo: GitDiff.Repo?, baseline: GitDiff.Baseline?,
                            changes: [GitDiff.FileChange], candidates: [String],
                            uncommitted: Int) {
        guard token == loadToken, let directory else { return }
        repoRoot = repo?.root
        if let root = repo?.root { watcher.watch(root: root) } else { watcher.stop() }
        fillBaseRefPopup(candidates, selecting: baseline?.name)
        // A load that ends without a summary falls back to the bare path, so
        // the last load's summary doesn't stay up describing something else.
        if repo == nil || baseline == nil {
            pathLabel.stringValue = (directory as NSString).abbreviatingWithTildeInPath
        }
        guard let repo else {
            self.changes = []
            fileTable.reloadData()
            showNote("Not a git repository:\n\(directory)")
            return
        }
        // Only branch mode can fail to resolve: HEAD always exists in a repo
        // with at least one commit, and a repo without one has nothing to show
        // either way.
        guard let baseline else {
            self.changes = []
            fileTable.reloadData()
            showNote("""
                Gutter can't tell what this branch would be based on.

                It looks for origin/HEAD, then origin/main, origin/master, \
                main, and master, and takes the merge base with the first one \
                that exists. A repo with no remote and no default branch - or \
                one whose history has nothing in common with it - has no answer.

                Pick a branch from the popup beside the toggle, if this repo \
                has one, or switch back to Uncommitted to see the working tree.
                """)
            return
        }

        baseRev = baseline.rev
        self.changes = changes
        fileTable.reloadData()

        var summary = (repo.root as NSString).abbreviatingWithTildeInPath
        if let branch = repo.branch { summary += "  ·  \(branch)" }
        summary += "  ·  \(baseline.label)"
        summary += changes.count == 1 ? "  ·  1 file" : "  ·  \(changes.count) files"
        if uncommitted > 0 { summary += " (\(uncommitted) not yet committed)" }
        switch base {
        case .uncommitted:
            leftPaneLabel.stringValue = "HEAD"
            pathLabel.toolTip = "The left pane is HEAD, the right pane the worktree."
        case .branch:
            // GitHub labels the left side of a PR diff with the base branch,
            // so this does too. The commit it actually reads from is in the
            // tooltip, for when that is the question.
            leftPaneLabel.stringValue = baseline.name
            var tip = "The files a pull request into \(baseline.name) would show: "
                + "your branch since \(baseline.shortRev), the last commit the two still share."
            if baseline.behind > 0 {
                let n = baseline.behind
                tip += " \(baseline.name) has \(n) commit\(n == 1 ? "" : "s") since then, "
                    + "which a PR would not count as your work, so they are not changes here."
            }
            if uncommitted == 1 {
                tip += " One file here isn't committed yet, so a PR wouldn't show it."
            } else if uncommitted > 1 {
                tip += " \(uncommitted) files here aren't committed yet, "
                    + "so a PR wouldn't show them."
            }
            pathLabel.toolTip = tip
        }
        pathLabel.stringValue = summary

        guard !changes.isEmpty else {
            switch base {
            case .uncommitted:
                showNote("No uncommitted changes.")
            case .branch:
                // Sitting on the default branch with nothing dirty is the
                // ordinary way to land here, and "no changes" alone reads like
                // something went wrong.
                showNote("""
                    Nothing here that \(baseline.name) doesn't already have.

                    This branch hasn't diverged from it, and the working tree \
                    is clean - a PR opened now would be empty.
                    """)
            }
            return
        }
        // Keep the file that was open across a refresh when it's still dirty.
        let index = changes.firstIndex { $0.path == selectedPath } ?? 0
        fileTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        fileTable.scrollRowToVisible(index)
        showFile(at: index)
    }

    /// The picker shows what the load actually resolved to, which isn't always
    /// what was remembered: `GitDiff.baseline` falls back to the inferred
    /// default when a picked branch has been deleted, and the popup follows it
    /// rather than keeping a stale name selected.
    private func fillBaseRefPopup(_ candidates: [String], selecting current: String?) {
        baseRefPopup.isHidden = base != .branch
        guard base == .branch else { return }

        var items = candidates
        // The resolved base belongs in the list even when `candidateRefs`
        // skipped it - sitting on `main` in a repo with no remote resolves to
        // `main`, which it drops as the current branch.
        if let current, !items.contains(current) { items.insert(current, at: 0) }
        baseRefPopup.removeAllItems()
        baseRefPopup.addItems(withTitles: items)
        let fork = NSImage(systemSymbolName: "arrow.triangle.branch",
                           accessibilityDescription: "branch to fork from")
        for item in baseRefPopup.itemArray { item.image = fork }
        baseRefPopup.isEnabled = !items.isEmpty
        // Nothing resolved: show no selection rather than the first ref, which
        // would read as the base being used.
        if let current {
            baseRefPopup.selectItem(withTitle: current)
        } else {
            baseRefPopup.selectItem(at: -1)
        }
    }

    private func showFile(at index: Int) {
        guard let directory, changes.indices.contains(index) else { return }
        let change = changes[index]
        selectedPath = change.path

        loadToken += 1
        let token = loadToken
        let rev = baseRev
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitDiff.diff(change, in: directory, since: rev)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                switch result {
                case .note(let text): self.showNote(text)
                case .rows(let rows): self.showRows(rows)
                }
            }
        }
    }

    // MARK: Scrolling and change navigation

    /// Every row is exactly one line in the same font, so a row's offset is
    /// arithmetic - no need to ask the layout manager, which would force layout
    /// of the whole file just to find one line.
    private var lineHeight: CGFloat {
        leftView.layoutManager?.defaultLineHeight(for: Self.font) ?? 15
    }

    private var documentHeight: CGFloat {
        CGFloat(rowCount) * lineHeight + leftView.textContainerInset.height * 2
    }

    private func scrollPanes(toY y: CGFloat) {
        let visible = leftScroll.contentView.bounds.height
        let clamped = min(max(0, y), max(0, documentHeight - visible))
        syncingScroll = true
        for scroll in [leftScroll, rightScroll] {
            var origin = scroll.contentView.bounds.origin
            origin.y = clamped
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        syncingScroll = false
        updateMapViewport()
    }

    /// A click on the map: put that point of the file in the middle of the panes.
    private func scrollPanes(toFraction fraction: CGFloat) {
        scrollPanes(toY: documentHeight * fraction - leftScroll.contentView.bounds.height / 2)
    }

    private func scrollPanes(toRow row: Int) {
        // A third of the way down, not centered: the lines after a change are
        // usually the ones you want to read.
        let y = leftView.textContainerInset.height + CGFloat(row) * lineHeight
        scrollPanes(toY: y - leftScroll.contentView.bounds.height / 3)
    }

    /// The row at the top of the panes right now.
    private var topRow: Int {
        let y = leftScroll.contentView.bounds.origin.y - leftView.textContainerInset.height
        return max(0, Int((y / lineHeight).rounded()))
    }

    @objc private func nextChange(_ sender: Any?) {
        guard !blocks.isEmpty else { return }
        // Wraps: at the last change, the next one is the first again.
        let target = blocks.first { $0.start > topRow } ?? blocks[0]
        scrollPanes(toRow: target.start)
    }

    @objc private func previousChange(_ sender: Any?) {
        guard !blocks.isEmpty else { return }
        let target = blocks.last { $0.start < topRow } ?? blocks[blocks.count - 1]
        scrollPanes(toRow: target.start)
    }

    private func updateMapViewport() {
        let height = documentHeight
        guard height > 0 else { return mapView.viewport = nil }
        let origin = leftScroll.contentView.bounds.origin.y
        let visible = leftScroll.contentView.bounds.height
        mapView.viewport = (origin / height)...(min(1, (origin + visible) / height))
    }

    // MARK: Rendering

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func showNote(_ text: String) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        leftView.textStorage?.setAttributedString(attributed)
        rightView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        rowCount = 0
        blocks = []
        mapView.blocks = []
        mapView.totalRows = 0
        shownRows = []
        leftBodyStarts = []
        rightBodyStarts = []
        runFind(jump: false)
        scrollPanesToTop()
    }

    private func showRows(_ rows: [GitDiff.Row]) {
        // Backgrounds only cover the glyphs they sit under, so every line is
        // padded to a common width - otherwise a changed row's highlight would
        // stop at the end of its text and the two panes would look ragged.
        let widest = rows.reduce(0) { max($0, max($1.left?.count ?? 0, $1.right?.count ?? 0)) }
        let padTo = min(max(widest, 80), 500)

        leftView.textStorage?.setAttributedString(
            render(rows, side: .left, padTo: padTo, bodyStarts: &leftBodyStarts))
        rightView.textStorage?.setAttributedString(
            render(rows, side: .right, padTo: padTo, bodyStarts: &rightBodyStarts))

        rowCount = rows.count
        blocks = Self.blocks(in: rows)
        mapView.totalRows = rows.count
        mapView.blocks = blocks
        shownRows = rows
        // A query stays live across files and refreshes: the question is
        // usually "where else is this used", and the next file is where else.
        runFind(jump: false)
        scrollPanesToTop()
    }

    private enum Side { case left, right }

    private func render(_ rows: [GitDiff.Row], side: Side, padTo: Int,
                        bodyStarts: inout [Int]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        bodyStarts = []
        bodyStarts.reserveCapacity(rows.count)
        for row in rows {
            let text = side == .left ? row.left : row.right
            let number = side == .left ? row.leftNumber : row.rightNumber

            // A missing line is the blank counterpart of an insertion or a
            // deletion on the other side: it holds the row open so both panes
            // stay on the same line.
            let gutter = number.map { String(format: "%5d  ", $0) } ?? "       "
            let body = text ?? ""
            let padded = body + String(repeating: " ", count: max(0, padTo - body.count))
            let line = NSMutableAttributedString(string: gutter + padded + "\n", attributes: [
                .font: Self.font,
                .foregroundColor: NSColor.labelColor,
            ])
            let lineRange = NSRange(location: 0, length: line.length)
            let gutterWidth = gutter.utf16.count
            line.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                              range: NSRange(location: 0, length: gutterWidth))

            switch (row.kind, side) {
            case (.equal, _):
                break
            case (.changed, _):
                line.addAttribute(.backgroundColor, value: Self.changedBG, range: lineRange)
                // Narrow the highlight to the part that actually differs, so a
                // one-character edit doesn't light up the whole line.
                if let left = row.left, let right = row.right,
                   let (leftRange, rightRange) = GitDiff.intralineRanges(left, right) {
                    let range = side == .left ? leftRange : rightRange
                    if range.length > 0 {
                        let shifted = NSRange(location: range.location + gutterWidth,
                                              length: range.length)
                        line.addAttribute(.backgroundColor, value: Self.intralineBG, range: shifted)
                    }
                }
            case (.removed, .left):
                line.addAttribute(.backgroundColor, value: Self.removedBG, range: lineRange)
            case (.added, .right):
                line.addAttribute(.backgroundColor, value: Self.addedBG, range: lineRange)
            case (.removed, .right), (.added, .left):
                line.addAttribute(.backgroundColor, value: Self.fillerBG, range: lineRange)
            }
            // The gutter is not a fixed width - a sixth digit widens it - so
            // the text's start is recorded rather than assumed.
            bodyStarts.append(out.length + gutterWidth)
            out.append(line)
        }
        return out
    }

    private func scrollPanesToTop() {
        syncingScroll = true
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        syncingScroll = false
        // The text views have just been handed new content; their frames catch
        // up on the next layout pass, and the viewport is measured against them.
        DispatchQueue.main.async { [weak self] in self?.updateMapViewport() }
    }

    /// Runs of adjacent non-equal rows. One edit is one mark on the map and one
    /// stop for the next/previous-change buttons, however many lines it spans.
    private static func blocks(in rows: [GitDiff.Row]) -> [DiffMapView.Block] {
        var blocks: [DiffMapView.Block] = []
        var i = 0
        while i < rows.count {
            guard rows[i].kind != .equal else {
                i += 1
                continue
            }
            let start = i
            var added = false, removed = false, changed = false
            while i < rows.count, rows[i].kind != .equal {
                switch rows[i].kind {
                case .added: added = true
                case .removed: removed = true
                case .changed: changed = true
                case .equal: break
                }
                i += 1
            }
            let color: NSColor
            if changed || (added && removed) {
                color = mapChanged
            } else {
                color = added ? mapAdded : mapRemoved
            }
            blocks.append(DiffMapView.Block(start: start, end: i - 1, color: color))
        }
        return blocks
    }

    // MARK: Find
    //
    // One bar over both panes, searching whichever pane is active - meld's
    // shape. Hand-written rather than NSTextFinder, which would give each pane
    // its own bar and match line numbers and padding along with the text.
    // The Edit menu's Find items reach this through AppDelegate, which sends
    // them here while this window is key and to the terminal otherwise.

    private func makeFindBar() {
        findSideToggle.segmentCount = 2
        findSideToggle.trackingMode = .selectOne
        findSideToggle.setImage(NSImage(systemSymbolName: "rectangle.lefthalf.filled",
                                        accessibilityDescription: "Left pane"), forSegment: 0)
        findSideToggle.setImage(NSImage(systemSymbolName: "rectangle.righthalf.filled",
                                        accessibilityDescription: "Right pane"), forSegment: 1)
        findSideToggle.setToolTip("Search the left pane (or click into it)", forSegment: 0)
        findSideToggle.setToolTip("Search the right pane (or click into it)", forSegment: 1)
        findSideToggle.selectedSegment = 1
        findSideToggle.target = self
        findSideToggle.action = #selector(findSideToggled(_:))
        // Focus, not selection changes: the panes' selections also move when
        // a file loads, which would flip the side behind the user's back.
        responderObservation = window?.observe(\.firstResponder) { [weak self] window, _ in
            guard let self else { return }
            if window.firstResponder === self.leftView {
                self.setFindSide(.left)
            } else if window.firstResponder === self.rightView {
                self.setFindSide(.right)
            }
        }

        findField.placeholderString = "Find in this file"
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(findQueryChanged(_:))
        findField.delegate = self
        findField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        findCountLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        findCountLabel.textColor = .secondaryLabelColor

        // Left and right chevrons, like Safari's find bar - the up/down pair in
        // the header already means "change", and these step through matches.
        // No key equivalents: ⌘G and ⇧⌘G are the Edit menu's.
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.left",
                                               accessibilityDescription: "Previous Match")!,
                                target: self, action: #selector(previousMatchClicked(_:)))
        previous.toolTip = "Previous Match (⇧⌘G or ⇧↵)"
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.right",
                                           accessibilityDescription: "Next Match")!,
                            target: self, action: #selector(nextMatchClicked(_:)))
        next.toolTip = "Next Match (⌘G or ↵)"
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked(_:)))
        done.toolTip = "Close the find bar (esc)"
        for button in [previous, next, done] { button.bezelStyle = .rounded }

        findBar.orientation = .horizontal
        findBar.spacing = 8
        findBar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 6, right: 12)
        findBar.setViews([findSideToggle, findField, previous, next, findCountLabel], in: .leading)
        findBar.setViews([done], in: .trailing)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.heightAnchor.constraint(equalToConstant: 30).isActive = true
        findBar.isHidden = true
    }

    /// ⌘F: show the bar and put the cursor in it, with the last query selected
    /// so typing replaces it - the same as every other macOS find field.
    func beginFind() {
        let wasHidden = findBar.isHidden
        findBar.isHidden = false
        window?.makeFirstResponder(findField)
        if wasHidden { runFind(jump: false) }
    }

    /// ⌘G / ⇧⌘G. With the bar closed, a query from before reopens it and
    /// steps; with no query there is nothing to step through, so it opens the
    /// bar for one instead.
    func stepFind(forward: Bool) {
        guard !findField.stringValue.isEmpty else { return beginFind() }
        if findBar.isHidden {
            findBar.isHidden = false
            runFind(jump: false)
        }
        stepMatch(forward: forward)
    }

    /// ⌘E: search for what is selected in the active pane - selecting text
    /// focuses the pane, so that is the one it was selected in. Only its first
    /// line, trimmed: a selection dragged across rows carries line numbers and
    /// the padding that squares the panes off.
    func findSelection() {
        let view = findView
        guard view.selectedRange().length > 0,
              let text = view.textStorage?.attributedSubstring(from: view.selectedRange()).string,
              let line = text.split(whereSeparator: \.isNewline).first
        else { return }
        let needle = line.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return }
        findField.stringValue = needle
        findBar.isHidden = false
        runFind(jump: false)
    }

    private func endFind() {
        findBar.isHidden = true
        runFind(jump: false)
        // Back to the pane that was searched; the other would flip the side.
        window?.makeFirstResponder(findView)
    }

    private var findView: NSTextView { findSide == .left ? leftView : rightView }

    @objc private func findSideToggled(_ sender: Any?) {
        setFindSide(findSideToggle.selectedSegment == 0 ? .left : .right)
    }

    /// Re-searches on a switch but doesn't jump: the query is the same, only
    /// the pane changed, so the reader stays where they are.
    private func setFindSide(_ side: Side) {
        guard side != findSide else { return }
        findSide = side
        runFind(jump: false)
    }

    /// The searched pane has to be obvious, or "No matches" reads as a bug
    /// when the string is sitting in the other pane. So while the bar is open
    /// it says so four ways: the toggle in the bar, an accent border around
    /// the pane, its caption in the accent color, and the field's placeholder.
    /// With the bar closed nothing is marked - no find, no active pane.
    private func updateActivePane() {
        let finding = !findBar.isHidden
        findSideToggle.selectedSegment = findSide == .left ? 0 : 1
        let panes: [(NSScrollView, NSTextField, Side)] = [
            (leftScroll, leftPaneLabel, .left), (rightScroll, rightPaneLabel, .right),
        ]
        for (scroll, caption, side) in panes {
            let active = finding && side == findSide
            scroll.layer?.borderWidth = active ? 2 : 0
            scroll.layer?.borderColor = NSColor.controlAccentColor.cgColor
            caption.textColor = active ? .controlAccentColor : .secondaryLabelColor
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: active ? .semibold : .medium)
        }
        let caption = findSide == .left ? leftPaneLabel.stringValue : rightPaneLabel.stringValue
        findField.placeholderString = "Find in \(caption)"
    }

    @objc private func findQueryChanged(_ sender: Any?) {
        guard findField.stringValue != searchedNeedle else { return }
        runFind(jump: true)
    }

    @objc private func nextMatchClicked(_ sender: Any?) { stepMatch(forward: true) }
    @objc private func previousMatchClicked(_ sender: Any?) { stepMatch(forward: false) }
    @objc private func doneClicked(_ sender: Any?) { endFind() }

    /// Return steps forward and shift-Return back, as in Safari and VS Code;
    /// Escape closes the bar. Without this the search field takes Escape to
    /// clear the query and leaves the bar open.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            // Return is also the field's end-editing action; a query typed
            // faster than the action fired is caught up here first.
            if findField.stringValue != searchedNeedle { runFind(jump: false) }
            stepMatch(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endFind()
            return true
        default:
            return false
        }
    }

    /// Rebuild `matches` for the current query and file. `jump` is for typing:
    /// it moves to the first match at or below the top of the panes, so the
    /// reader's place survives a query that matches what they're looking at.
    private func runFind(jump: Bool) {
        let needle = findField.stringValue
        searchedNeedle = needle
        matches = []
        currentMatch = nil
        if !findBar.isHidden, !needle.isEmpty {
            for (index, row) in shownRows.enumerated() {
                // A filler row has no text on this side - the line exists
                // only in the other pane.
                guard let text = findSide == .left ? row.left : row.right else { continue }
                for range in Self.occurrences(of: needle, in: text) {
                    matches.append(FindMatch(row: index, range: range))
                }
            }
        }
        // Here rather than at each caller: a load renames the left caption,
        // and every load ends in a find.
        updateActivePane()
        for view in [leftView, rightView] {
            guard let length = view.textStorage?.length else { continue }
            view.layoutManager?.removeTemporaryAttribute(
                .backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        }
        for index in matches.indices { paintMatch(index) }
        mapView.matchRows = matches.map(\.row)
        if jump, !matches.isEmpty { stepMatch(forward: true) } else { updateFindCount() }
    }

    /// Case-insensitive and literal, like VS Code's default. Non-overlapping,
    /// so "aa" in "aaaa" is two matches, not three.
    private static func occurrences(of needle: String, in text: String) -> [NSRange] {
        let haystack = text as NSString
        var found: [NSRange] = []
        var from = 0
        while from < haystack.length {
            let range = haystack.range(of: needle, options: .caseInsensitive,
                                       range: NSRange(location: from, length: haystack.length - from))
            guard range.location != NSNotFound else { break }
            found.append(range)
            from = range.location + max(range.length, 1)
        }
        return found
    }

    /// The match's range in the searched pane's text storage.
    private func paneRange(_ match: FindMatch) -> NSRange {
        let start = (findSide == .left ? leftBodyStarts : rightBodyStarts)[match.row]
        return NSRange(location: start + match.range.location, length: match.range.length)
    }

    /// Temporary attributes, not text-storage ones: they draw over the diff's
    /// own backgrounds without replacing them, so clearing a find is removing
    /// them again rather than re-rendering the file.
    private func paintMatch(_ index: Int) {
        let color = index == currentMatch ? Self.currentMatchBG : Self.matchBG
        findView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: color,
                                                      forCharacterRange: paneRange(matches[index]))
    }

    private func stepMatch(forward: Bool) {
        guard !matches.isEmpty else { return updateFindCount() }
        let target: Int
        if let current = currentMatch {
            // Wraps, like the change jumps.
            target = (current + (forward ? 1 : matches.count - 1)) % matches.count
        } else {
            // Nothing stepped to yet: start from where the reader is.
            let top = topRow
            target = forward
                ? matches.firstIndex { $0.row >= top } ?? 0
                : matches.lastIndex { $0.row < top } ?? matches.count - 1
        }
        let previous = currentMatch
        currentMatch = target
        if let previous { paintMatch(previous) }
        paintMatch(target)
        updateFindCount()

        let match = matches[target]
        // Only scroll when the row is off screen: typing a query that matches
        // the line being read shouldn't move it.
        let visibleRows = Int(leftScroll.contentView.bounds.height / lineHeight)
        if match.row < topRow || match.row >= topRow + max(1, visibleRows - 1) {
            scrollPanes(toRow: match.row)
        }
        let range = paneRange(match)
        // The panes don't wrap, so a match far along a long line can be off to
        // the right; this scrolls sideways, and the scroll sync carries the
        // other pane along.
        findView.scrollRangeToVisible(range)
        findView.showFindIndicator(for: range)
    }

    private func updateFindCount() {
        if searchedNeedle.isEmpty || findBar.isHidden {
            findCountLabel.stringValue = ""
        } else if matches.isEmpty {
            findCountLabel.stringValue = "No matches"
        } else if let currentMatch {
            findCountLabel.stringValue = "\(currentMatch + 1) of \(matches.count)"
        } else {
            findCountLabel.stringValue = matches.count == 1 ? "1 match" : "\(matches.count) matches"
        }
    }

    // MARK: File list

    func numberOfRows(in tableView: NSTableView) -> Int { changes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard changes.indices.contains(row) else { return nil }
        let change = changes[row]
        let label = NSTextField(labelWithString: "\(change.status)  \(change.path)")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingHead
        label.toolTip = change.oldPath.map { "\($0) -> \(change.path)" } ?? change.path
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = fileTable.selectedRow
        guard row >= 0 else { return }
        showFile(at: row)
    }
}

/// Wraps a plain view so it can be handed to an NSSplitViewController, which
/// only takes view controllers.
private final class HostingViewController: NSViewController {
    private let content: NSView

    init(_ content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        // A hosting view keeps the default .none mask, so it never followed the
        // window when the autosaved frame was restored after the content was
        // installed: the UI stayed at the fitting size it was given, pinned to
        // the bottom of a window that had grown around it.
        content.autoresizingMask = [.width, .height]
        view = content
    }
}

/// The strip between the panes: one mark per change, the whole file squeezed
/// into a column a few points wide, plus an outline showing what the panes are
/// currently looking at. Click or drag it to jump.
///
/// It doubles as the divider between the two panes, so the panes lose nothing
/// to it - meld's map earns its width the same way.
final class DiffMapView: NSView {
    struct Block {
        let start: Int
        let end: Int
        let color: NSColor
    }

    static let width: CGFloat = 14

    var blocks: [Block] = [] { didSet { needsDisplay = true } }
    var totalRows = 0 { didSet { needsDisplay = true } }
    /// Rows holding a find match. This is the "where else in the file" answer
    /// at a glance, the same way the blocks are for changes.
    var matchRows: [Int] = [] { didSet { needsDisplay = true } }
    /// The visible span of the file, as a 0...1 fraction. Nil hides the outline.
    var viewport: ClosedRange<CGFloat>? { didSet { needsDisplay = true } }
    /// Where the user clicked, as a 0...1 fraction of the file.
    var onJump: ((CGFloat) -> Void)?

    // Top-down coordinates: a diff reads from the top, and so does the map.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        guard totalRows > 0 else { return }
        let inset: CGFloat = 2
        let usable = bounds.height
        let scale = usable / CGFloat(totalRows)

        for block in blocks {
            let top = CGFloat(block.start) * scale
            // Never thinner than 2 points: a one-line change in a long file
            // would round away to nothing and the map would lie.
            let height = max(2, CGFloat(block.end - block.start + 1) * scale)
            block.color.setFill()
            NSRect(x: inset, y: top, width: bounds.width - inset * 2, height: height).fill()
        }

        // Narrower than a change mark, so a match inside a change leaves the
        // change's color showing at the edges.
        NSColor.systemYellow.setFill()
        for row in matchRows {
            NSRect(x: inset * 2, y: CGFloat(row) * scale, width: bounds.width - inset * 4, height: 2).fill()
        }

        if let viewport {
            let top = viewport.lowerBound * usable
            let height = max(4, (viewport.upperBound - viewport.lowerBound) * usable)
            let rect = NSRect(x: 0.5, y: top + 0.5, width: bounds.width - 1, height: height - 1)
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            rect.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { jump(to: event) }

    override func mouseDragged(with event: NSEvent) { jump(to: event) }

    private func jump(to event: NSEvent) {
        guard totalRows > 0, bounds.height > 0 else { return }
        let y = convert(event.locationInWindow, from: nil).y
        onJump?(min(max(0, y / bounds.height), 1))
    }

    override func resetCursorRects() {
        // Pointing hand: the strip is a control, not a passive ruler.
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
