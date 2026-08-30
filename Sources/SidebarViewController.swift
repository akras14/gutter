import AppKit
import GhosttyKit

/// Source-list sidebar: one row per session with a title and an activity dot.
final class SidebarViewController: NSViewController {
    private let sessions: SessionManager
    private var tableView: NSTableView!

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
        table.rowHeight = 30
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sessions"))
        column.width = 220
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        self.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        view = visualEffect
    }

    func reload() {
        guard isViewLoaded else { return }
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
        cell.configure(title: session.displayName, active: session.hasActivity)
        return cell
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

/// Title + activity dot for one sidebar row.
final class SessionCellView: NSTableCellView {
    private let dot = ActivityDotView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title: String, active: Bool) {
        label.stringValue = title
        dot.isActive = active
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            label.textColor = backgroundStyle == .emphasized ? .white : .labelColor
        }
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
