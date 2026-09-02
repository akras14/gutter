import AppKit
import GhosttyKit

/// Source-list sidebar: one row per session with a title and an activity dot.
final class SidebarViewController: NSViewController {
    /// Local-only drag type: rows move within this table and nowhere else.
    private static let rowType = NSPasteboard.PasteboardType("com.gutter.session-row")

    private let sessions: SessionManager
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var lastFittedWidth: CGFloat = 0
    /// Row being renamed, and a reload that arrived while it was. A shell title
    /// update reloads the table, which would tear the field editor out from
    /// under the user mid-edit; hold it until the edit finishes.
    private var renamingRow: Int?
    private var pendingReload = false

    init(sessions: SessionManager) {
        self.sessions = sessions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        let table = NSTableView()
        table.headerView = nil
        table.style = .sourceList
        table.selectionHighlightStyle = .regular
        // Two lines per row. Fixed rather than per-row: a session's second line
        // comes and goes as the shell reports a title, and rows that changed
        // height under the pointer looked ragged.
        table.rowHeight = 44
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sessions"))
        // Width is a placeholder; viewDidLayout keeps it matched to the visible
        // sidebar. A column wider than the sidebar pushes the trailing shortcut
        // hint off-screen until the user drags the divider past it.
        column.minWidth = 60
        column.width = 170
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        self.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scroll
        visualEffect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        view = visualEffect
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Keep the single column exactly as wide as the visible sidebar, or
        // each row's trailing shortcut hint sits outside it and gets clipped.
        // Let AppKit compute the fit: deriving it by hand from the clip view's
        // width overshot by the source-list inset and intercell spacing, which
        // was enough to cut the digit off "⌘1". Guarded on the clip width so a
        // resize during layout can't feed back into another layout pass.
        let width = scrollView.contentSize.width
        guard width > 0, abs(width - lastFittedWidth) > 0.5 else { return }
        lastFittedWidth = width
        tableView.sizeLastColumnToFit()
    }

    func reload() {
        guard isViewLoaded else { return }
        guard renamingRow == nil else {
            pendingReload = true
            return
        }
        tableView.reloadData()
        syncSelectionRow()
    }

    private func syncSelectionRow() {
        guard let selected = sessions.selected,
              let idx = sessions.sessions.firstIndex(where: { $0 === selected }) else {
            tableView.deselectAll(nil)
            return
        }
        if tableView.selectedRow != idx {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < sessions.sessions.count else { return }
        sessions.select(sessions.sessions[row])
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        beginRename(row: tableView.clickedRow)
    }

    /// Entry point for the Rename Tab menu item.
    func beginRenameSelected() {
        guard let selected = sessions.selected,
              let row = sessions.sessions.firstIndex(where: { $0 === selected }) else { return }
        beginRename(row: row)
    }

    private func beginRename(row: Int) {
        guard renamingRow == nil, row >= 0, row < sessions.sessions.count else { return }
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionCellView else { return }
        renamingRow = row
        // Seed with the custom name and nothing else: an unnamed session opens
        // an empty field. Seeding it with the shell title instead made Enter
        // look like it had rewritten the row on its own. What the row would
        // show without a name becomes the placeholder, so clearing the field
        // visibly means "go back to that".
        let session = sessions.sessions[row]
        cell.beginRename(seed: session.customTitle ?? "",
                         placeholder: session.autoTitle,
                         delegate: self)
    }

    private func finishRename(field: NSTextField, commit: Bool) {
        // endRename resigns first responder, which fires controlTextDidEndEditing
        // a second time. Clearing the row first makes the re-entry a no-op.
        guard let row = renamingRow else { return }
        renamingRow = nil

        let name = field.stringValue
        (field.superview as? SessionCellView)?.endRename()
        if commit, row < sessions.sessions.count {
            sessions.rename(sessions.sessions[row], to: name)
        }
        // The terminal always owns focus in this app; without this the table
        // keeps first responder and keystrokes go nowhere.
        if let selected = sessions.selected {
            view.window?.makeFirstResponder(selected.view)
        }
        pendingReload = false
        reload()
    }
}

extension SidebarViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        finishRename(field: field, commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              let field = control as? NSTextField else { return false }
        finishRename(field: field, commit: false)
        return true
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        sessions.sessions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = sessions.sessions[row]
        let cellID = NSUserInterfaceItemIdentifier("SessionCell")
        let cell: SessionCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? SessionCellView {
            cell = reused
        } else {
            cell = SessionCellView()
            cell.identifier = cellID
        }
        cell.configure(primary: session.primaryLine,
                       secondary: session.secondaryLine,
                       active: session.needsAttention,
                       shortcut: row < 9 ? "⌘\(row + 1)" : "")
        cell.onClose = { [weak self] in self?.sessions.close(session) }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        // Only between rows, and only for a drag that started in this table -
        // dropping *on* a row would read as "open in", which means nothing here.
        guard op == .above, info.draggingSource as AnyObject === tableView else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: Self.rowType),
              let from = Int(raw) else { return false }
        sessions.move(from: from, to: row)
        return true
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard edge == .trailing, row < sessions.sessions.count else { return [] }
        let action = NSTableViewRowAction(style: .destructive, title: "Close") { [weak self] _, r in
            guard let self, r < self.sessions.sessions.count else { return }
            self.sessions.close(self.sessions.sessions[r])
        }
        return [action]
    }
}

/// Two lines per session - a stable one over a live one - plus the activity
/// dot, the shortcut hint, and a close button that takes the dot's place while
/// the pointer is over the row.
final class SessionCellView: NSTableCellView {
    private let dot = ActivityDotView()
    private let close = NSButton()
    private let label = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    /// A field with no chrome of its own, over an opaque box. Both the label
    /// made editable and a normal bezeled field ended up unreadable: a selected
    /// row makes every control inside it draw emphasized, so the bezel came out
    /// translucent and the black text sat on the blue selection. The box is not
    /// a control, so nothing recolours it.
    private let editorBackdrop = NSBox()
    private let editor = NSTextField()
    /// Only one of these is ever active: the pair sits astride the row's centre
    /// when there are two lines, and a lone title sits on it.
    private var stackedConstraint: NSLayoutConstraint!
    private var centeredConstraint: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var twoLine = false
    private var renaming = false

    /// Set on every configure, so it always closes the row it is drawn on.
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        for field in [label, subtitle] {
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        subtitle.font = .systemFont(ofSize: NSFont.systemFontSize - 1)
        hint.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 2, weight: .regular)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        hint.setContentHuggingPriority(.required, for: .horizontal)
        dot.translatesAutoresizingMaskIntoConstraints = false

        close.translatesAutoresizingMaskIntoConstraints = false
        close.isBordered = false
        close.bezelStyle = .inline
        close.imagePosition = .imageOnly
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close session")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        close.image?.isTemplate = true
        close.toolTip = "Close session"
        close.isHidden = true
        close.target = self
        close.action = #selector(closeClicked)

        editorBackdrop.translatesAutoresizingMaskIntoConstraints = false
        editorBackdrop.boxType = .custom
        editorBackdrop.titlePosition = .noTitle
        editorBackdrop.contentViewMargins = .zero
        editorBackdrop.fillColor = .textBackgroundColor
        editorBackdrop.borderColor = .separatorColor
        editorBackdrop.borderWidth = 1
        editorBackdrop.cornerRadius = 5
        editorBackdrop.isHidden = true

        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.isBezeled = false
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.isEditable = true
        editor.isSelectable = true
        editor.lineBreakMode = .byTruncatingTail
        editor.usesSingleLineMode = true
        editor.isHidden = true

        addSubview(dot)
        addSubview(close)
        addSubview(label)
        addSubview(subtitle)
        addSubview(hint)
        addSubview(editorBackdrop)
        addSubview(editor)

        stackedConstraint = label.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        centeredConstraint = label.centerYAnchor.constraint(equalTo: centerYAnchor)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            // Same slot as the dot, but centred on the row and big enough to
            // hit: the two are never on screen together.
            close.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -6),
            subtitle.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hint.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            // The field covers the whole row rather than one of its lines -
            // what is being renamed is the session, not a line of it.
            editorBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            editorBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            editorBackdrop.centerYAnchor.constraint(equalTo: centerYAnchor),
            editorBackdrop.heightAnchor.constraint(equalToConstant: 24),
            editor.leadingAnchor.constraint(equalTo: editorBackdrop.leadingAnchor, constant: 6),
            editor.trailingAnchor.constraint(equalTo: editorBackdrop.trailingAnchor, constant: -6),
            editor.centerYAnchor.constraint(equalTo: editorBackdrop.centerYAnchor),
            stackedConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(primary: String, secondary: String, active: Bool, shortcut: String) {
        label.stringValue = primary
        subtitle.stringValue = secondary
        setTwoLine(!secondary.isEmpty)
        hint.stringValue = shortcut
        hint.isHidden = shortcut.isEmpty
        dot.isActive = active
        applyTextColors()
        // Cells are recycled, so a reload under a stationary pointer has to
        // re-decide hover from where the mouse actually is - no enter/exit
        // event arrives for a row that was simply re-drawn.
        setHovered(pointerIsInside)
        needsLayout = true
    }

    private func setTwoLine(_ twoLine: Bool) {
        self.twoLine = twoLine
        subtitle.isHidden = !twoLine
        // Deactivate first: both active at once is an unsatisfiable pair.
        (twoLine ? centeredConstraint : stackedConstraint)?.isActive = false
        (twoLine ? stackedConstraint : centeredConstraint)?.isActive = true
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private var pointerIsInside: Bool {
        guard let window, window.isKeyWindow || NSApp.isActive else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard !renaming else { return }
        close.isHidden = !hovered
        dot.isHidden = hovered
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: - Rename

    /// Swap the whole row for an editable field. Everything else hides for the
    /// duration - the shortcut hint reads as part of the field otherwise, and
    /// the two labels would show through beside it.
    func beginRename(seed: String, placeholder: String, delegate: NSTextFieldDelegate) {
        renaming = true
        editor.stringValue = seed
        editor.placeholderString = placeholder
        editor.delegate = delegate
        // Set every time: an emphasized row repaints controls inside it, and
        // an explicit colour is what survives that.
        editor.textColor = .textColor
        editor.isHidden = false
        editorBackdrop.isHidden = false
        label.isHidden = true
        subtitle.isHidden = true
        hint.isHidden = true
        dot.isHidden = true
        close.isHidden = true
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    func endRename() {
        renaming = false
        editor.delegate = nil
        editor.isHidden = true
        editorBackdrop.isHidden = true
        label.isHidden = false
        subtitle.isHidden = !twoLine
        hint.isHidden = hint.stringValue.isEmpty
        dot.isHidden = false
        close.isHidden = true
        applyTextColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColors() }
    }

    private func applyTextColors() {
        let emphasized = backgroundStyle == .emphasized
        label.textColor = emphasized ? .white : .labelColor
        subtitle.textColor = emphasized
            ? .white.withAlphaComponent(0.7)
            : .secondaryLabelColor
        hint.textColor = emphasized
            ? .white.withAlphaComponent(0.7)
            : .secondaryLabelColor
        close.contentTintColor = emphasized ? .white : .secondaryLabelColor
        if renaming { editor.textColor = .textColor }
    }
}

final class ActivityDotView: NSView {
    var isActive = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}
