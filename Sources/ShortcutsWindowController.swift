import AppKit

/// The Help menu's shortcut list: everything Gutter binds, in one panel.
///
/// The table below is written by hand and is the only place the shortcuts are
/// described, so it has to be kept in step with `MainMenu` (the menu items and
/// their key equivalents) and with `GitDiffWindowController` (its buttons carry
/// their own key equivalents). ghostty's own keybinds from the user's config
/// are deliberately left out - they are the user's, and Gutter doesn't know
/// them.
final class ShortcutsWindowController: NSWindowController {
    private typealias Shortcut = (keys: String, action: String)

    private static let sections: [(String, [Shortcut])] = [
        ("Tabs", [
            ("⌘T", "New tab"),
            ("⌘W", "Close tab (or the front window)"),
            ("⇧⌘R", "Rename tab"),
            ("⌘1 – ⌘9", "Select tab 1 to 9"),
            ("⌃Tab", "Next tab"),
            ("⌃⇧Tab", "Previous tab"),
        ]),
        ("View", [
            ("⌘B", "Toggle sidebar"),
            ("⌃⇧G", "Show uncommitted changes"),
        ]),
        ("Find", [
            ("⌘F", "Find in scrollback"),
            ("⌘G", "Find next"),
            ("⇧⌘G", "Find previous"),
            ("⌘E", "Use selection for find"),
        ]),
        ("Uncommitted Changes Window", [
            ("⌘]", "Next change"),
            ("⌘[", "Previous change"),
            ("⌘R", "Refresh"),
            ("⌘W", "Close window"),
        ]),
        ("Config", [
            ("⌘,", "Open the ghostty config"),
            ("⇧⌘,", "Reload the ghostty config"),
        ]),
        ("Help", [
            ("⌘?", "Keyboard shortcuts"),
        ]),
    ]

    convenience init() {
        // No resize control: the panel is exactly as big as its content, and
        // sized to fit at the end of this initializer.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        // Same reason as the diff window: the controller outlives a close, so
        // reopening from the menu must not resurrect a released window.
        window.isReleasedWhenClosed = false
        self.init(window: window)

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 20
        grid.rowSpacing = 7
        // Keys right-aligned against their descriptions: the eye runs down the
        // gap between the columns instead of hunting along ragged text.
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        for (index, section) in Self.sections.enumerated() {
            let header = NSTextField(labelWithString: section.0)
            header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            header.textColor = .secondaryLabelColor
            let headerRow = grid.addRow(with: [header, NSGridCell.emptyContentView])
            headerRow.mergeCells(in: NSRange(location: 0, length: 2))
            if index > 0 { headerRow.topPadding = 14 }

            for shortcut in section.1 {
                let keys = NSTextField(labelWithString: shortcut.keys)
                // Monospaced digits only: the symbols themselves look wrong in
                // a monospaced face, but the columns still need to line up.
                keys.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                let action = NSTextField(labelWithString: shortcut.action)
                action.textColor = .labelColor
                grid.addRow(with: [keys, action])
            }
        }

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: grid.fittingSize.width + 48,
                                     height: grid.fittingSize.height + 40))
        window.center()
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
