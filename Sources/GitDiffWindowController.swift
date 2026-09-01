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

    private var directory: String?
    private var changes: [GitDiff.FileChange] = []
    /// Kept across refreshes so a reload doesn't jump back to the first file.
    private var selectedPath: String?
    /// Bumped on every load; a result carrying a stale token is dropped, so a
    /// slow file can't overwrite the pane after the user picked another one.
    private var loadToken = 0
    /// Guards the two scroll observers against echoing each other forever.
    private var syncingScroll = false

    // Meld's palette, roughly: red for what HEAD had, green for what the
    // worktree has, blue for a line that exists on both sides but changed.
    // Low alpha so the text stays readable in either appearance.
    private static let removedBG = NSColor.systemRed.withAlphaComponent(0.16)
    private static let addedBG = NSColor.systemGreen.withAlphaComponent(0.16)
    private static let changedBG = NSColor.systemBlue.withAlphaComponent(0.13)
    private static let intralineBG = NSColor.systemBlue.withAlphaComponent(0.30)
    private static let fillerBG = NSColor.secondaryLabelColor.withAlphaComponent(0.08)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Uncommitted Changes"
        self.init(window: window)

        pathLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload(_:)))
        refresh.bezelStyle = .rounded
        refresh.keyEquivalent = "r"
        refresh.keyEquivalentModifierMask = [.command]

        let header = NSStackView(views: [pathLabel, refresh])
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

        let container = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(left)
        container.addSubview(divider)
        container.addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            right.topAnchor.constraint(equalTo: container.topAnchor),
            right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // Equal halves: the two sides always show the same rows, so a
            // draggable divider between them would only ever hide one of them.
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        return container
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

    // MARK: Rendering

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func showNote(_ text: String) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        leftView.textStorage?.setAttributedString(attributed)
        rightView.textStorage?.setAttributedString(NSAttributedString(string: ""))
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
