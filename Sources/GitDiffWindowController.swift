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
final class GitDiffWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
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
    /// Kept across refreshes so a reload doesn't jump back to the first file.
    private var selectedPath: String?
    /// Bumped on every load; a result carrying a stale token is dropped, so a
    /// slow file can't overwrite the pane after the user picked another one.
    private var loadToken = 0
    /// Guards the two scroll observers against echoing each other forever.
    private var syncingScroll = false
    /// Row count and change blocks of the file on screen, for the map strip and
    /// the next/previous-change jumps.
    private var rowCount = 0
    private var blocks: [DiffMapView.Block] = []

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

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Uncommitted Changes"
        // The controller outlives the close - cmd-w hides this window and the
        // shortcut brings the same one back - so the window must not be
        // released out from under that reference.
        window.isReleasedWhenClosed = false
        self.init(window: window)

        pathLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload(_:)))
        refresh.bezelStyle = .rounded
        refresh.keyEquivalent = "r"
        refresh.keyEquivalentModifierMask = [.command]

        let previous = navButton("chevron.up", "Previous Change (⌘[)", "[", #selector(previousChange(_:)))
        let next = navButton("chevron.down", "Next Change (⌘])", "]", #selector(nextChange(_:)))

        let header = NSStackView(views: [pathLabel, previous, next, refresh])
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

        let content = NSView()
        let container = HostingViewController(content)
        container.addChild(split)
        let body = split.view
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        content.addSubview(header)
        content.addSubview(body)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
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

        let left = stackedPane(title: paneTitle("HEAD"), scroll: leftScroll)
        let right = stackedPane(title: paneTitle("Working tree"), scroll: rightScroll)

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

    @objc private func reload(_ sender: Any?) {
        guard let directory else {
            pathLabel.stringValue = "no directory"
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

        pathLabel.stringValue = (directory as NSString).abbreviatingWithTildeInPath
        window?.subtitle = (directory as NSString).lastPathComponent
        showNote("Loading...")

        loadToken += 1
        let token = loadToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard FileManager.default.fileExists(atPath: directory) else {
                DispatchQueue.main.async { self?.finishLoad(token, repo: nil, changes: []) }
                return
            }
            let repo = GitDiff.repo(at: directory)
            let changes = repo == nil ? [] : GitDiff.changes(in: directory)
            DispatchQueue.main.async { self?.finishLoad(token, repo: repo, changes: changes) }
        }
    }

    private func finishLoad(_ token: Int, repo: GitDiff.Repo?, changes: [GitDiff.FileChange]) {
        guard token == loadToken, let directory else { return }
        guard let repo else {
            self.changes = []
            fileTable.reloadData()
            showNote("Not a git repository:\n\(directory)")
            return
        }

        self.changes = changes
        fileTable.reloadData()

        var summary = (repo.root as NSString).abbreviatingWithTildeInPath
        if let branch = repo.branch { summary += "  ·  \(branch)" }
        summary += changes.count == 1 ? "  ·  1 file" : "  ·  \(changes.count) files"
        pathLabel.stringValue = summary

        guard !changes.isEmpty else {
            showNote("No uncommitted changes.")
            return
        }
        // Keep the file that was open across a refresh when it's still dirty.
        let index = changes.firstIndex { $0.path == selectedPath } ?? 0
        fileTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        fileTable.scrollRowToVisible(index)
        showFile(at: index)
    }

    private func showFile(at index: Int) {
        guard let directory, changes.indices.contains(index) else { return }
        let change = changes[index]
        selectedPath = change.path

        loadToken += 1
        let token = loadToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitDiff.diff(change, in: directory)
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
        scrollPanesToTop()
    }

    private func showRows(_ rows: [GitDiff.Row]) {
        // Backgrounds only cover the glyphs they sit under, so every line is
        // padded to a common width - otherwise a changed row's highlight would
        // stop at the end of its text and the two panes would look ragged.
        let widest = rows.reduce(0) { max($0, max($1.left?.count ?? 0, $1.right?.count ?? 0)) }
        let padTo = min(max(widest, 80), 500)

        leftView.textStorage?.setAttributedString(render(rows, side: .left, padTo: padTo))
        rightView.textStorage?.setAttributedString(render(rows, side: .right, padTo: padTo))

        rowCount = rows.count
        blocks = Self.blocks(in: rows)
        mapView.totalRows = rows.count
        mapView.blocks = blocks
        scrollPanesToTop()
    }

    private enum Side { case left, right }

    private func render(_ rows: [GitDiff.Row], side: Side, padTo: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
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
