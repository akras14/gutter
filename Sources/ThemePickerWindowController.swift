import AppKit
import GhosttyKit

/// Gutter > Choose Theme...: the bundled themes, previewed live in every
/// window as the selection moves, and written to the config only on Save.
///
/// The preview is never written anywhere the user would see it. Each step
/// builds a config the way `Ghostty.Config` does - the user's file, its
/// includes, the embedder overrides - plus one more file holding just
/// `theme = <name>`, and hands it to the app. Closing without saving reloads
/// the real file, which puts back whatever it says.
///
/// Save is the one place Gutter edits an existing config file. It replaces the
/// last `theme =` line, or appends one, and touches nothing else - see
/// DESIGN.md, "The theme picker writes one line".
final class ThemePickerWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private struct Theme {
        let name: String
        let background: NSColor?
        let foreground: NSColor?
    }

    private let ghostty: Ghostty.App
    private let configPath: String
    private let ensureConfigFile: () -> Bool

    private var themes: [Theme] = []
    private var shown: [Theme] = []
    /// The theme being previewed, while one is. Its config is kept so Save can
    /// check the file now produces the same colours.
    private var preview: (name: String, config: Ghostty.Config)?
    /// Set while the table is reselected by code, so only the user's moves
    /// preview anything.
    private var reselecting = false

    private let search = NSSearchField()
    private let table = NSTableView()

    init(ghostty: Ghostty.App, configPath: String, ensureConfigFile: @escaping () -> Bool) {
        self.ghostty = ghostty
        self.configPath = configPath
        self.ensureConfigFile = ensureConfigFile
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Choose Theme"
        window.minSize = NSSize(width: 260, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildContent(in window: NSWindow) {
        search.placeholderString = "Search themes"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: .init("theme"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(save(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [search, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [search, scroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
    }

    // MARK: - Showing

    func present() {
        if themes.isEmpty { themes = Self.loadThemes() }
        search.stringValue = ""
        filter()
        if let current = currentTheme(), let row = shown.firstIndex(where: { $0.name == current }) {
            select(row: row)
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    /// Every bundled theme, with the two colours its row swatch is drawn in.
    /// Read straight from the theme files: there are a few hundred, each a
    /// few lines, and asking libghostty instead would mean a config per theme.
    private static func loadThemes() -> [Theme] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
                return Theme(name: name,
                             background: color(for: "background", in: text),
                             foreground: color(for: "foreground", in: text))
            }
    }

    private static func color(for key: String, in text: String) -> NSColor? {
        for line in text.split(separator: "\n") {
            guard let value = value(of: key, in: String(line)) else { continue }
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                           green: CGFloat((rgb >> 8) & 0xff) / 255,
                           blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        }
        return nil
    }

    /// The value of a `key = value` line, or nil when the line sets something
    /// else or is a comment.
    private static func value(of key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(key) else { return nil }
        let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        return rest.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// What the config file's last `theme =` line says - the one ghostty uses.
    private func currentTheme() -> String? {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n").compactMap { Self.value(of: "theme", in: $0) }.last
    }

    // MARK: - Filtering and moving

    private func filter() {
        let selected = table.selectedRow >= 0 && table.selectedRow < shown.count
            ? shown[table.selectedRow].name : nil
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = query.isEmpty ? themes : themes.filter { $0.name.localizedCaseInsensitiveContains(query) }
        reselecting = true
        table.reloadData()
        if let selected, let row = shown.firstIndex(where: { $0.name == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        reselecting = false
    }

    private func select(row: Int) {
        guard row >= 0, row < shown.count else { return }
        reselecting = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        reselecting = false
        table.scrollRowToVisible(row)
    }

    func controlTextDidChange(_ obj: Notification) {
        filter()
    }

    /// The search field keeps focus, so the arrows have to reach the list from
    /// there: type to narrow, arrow through the matches, Return to save.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let step: Int
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): step = 1
        case #selector(NSResponder.moveUp(_:)): step = -1
        case #selector(NSResponder.insertNewline(_:)):
            save(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(nil)
            return true
        default:
            return false
        }
        guard !shown.isEmpty else { return true }
        let row = table.selectedRow < 0 ? 0 : min(max(table.selectedRow + step, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ThemeCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ThemeCellView ?? ThemeCellView()
        cell.identifier = id
        let theme = shown[row]
        cell.configure(name: theme.name, background: theme.background, foreground: theme.foreground)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reselecting, table.selectedRow >= 0, table.selectedRow < shown.count else { return }
        showPreview(shown[table.selectedRow].name)
    }

    // MARK: - Preview, save, cancel

    private func showPreview(_ name: String) {
        guard let app = ghostty.app,
              let config = Self.config(path: configPath, theme: name) else { return }
        ghostty_app_update_config(app, config.config!)
        preview = (name, config)
    }

    /// The user's config with `theme = <name>` loaded last, after its includes
    /// and the embedder overrides, so nothing in the file can outvote it.
    private static func config(path: String, theme: String) -> Ghostty.Config? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gutter-theme-preview.conf")
        guard (try? "theme = \(theme)\n".write(to: url, atomically: true, encoding: .utf8)) != nil,
              let cfg = Ghostty.Config.loadConfig(at: path, finalize: false) else { return nil }
        ghostty_config_load_file(cfg, url.path)
        ghostty_config_finalize(cfg)
        return Ghostty.Config(config: cfg)
    }

    @objc private func cancel(_ sender: Any?) {
        window?.close()
    }

    @objc private func save(_ sender: Any?) {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return }
        let name = shown[table.selectedRow].name
        // A preview config for the check below, even when Save comes straight
        // from a reselection that never previewed.
        let expected = preview?.name == name ? preview?.config : Self.config(path: configPath, theme: name)
        // Alerts on its own when it can't create the file.
        guard ensureConfigFile() else { return }
        do {
            try write(theme: name)
        } catch {
            alert(title: "Could not save the theme", message: "\(configPath)\n\n\(error.localizedDescription)")
            return
        }
        preview = nil
        ghostty.reloadConfig()
        window?.close()

        // The file can still lose to something loaded after it, most likely a
        // `config-file` include that sets its own theme. The preview went in
        // last and never saw that, so say so rather than let Save look broken.
        let saved = Ghostty.Config(at: configPath)
        if let expected, Self.background(of: saved) != Self.background(of: expected) {
            alert(title: "Saved, but another setting overrides it",
                  message: "\"theme = \(name)\" is in \(configPath), but something loaded after it "
                      + "sets the colours - usually a config-file line that includes a theme of its own.")
        }
    }

    /// Replace the last `theme =` line, the one in effect, or append one.
    /// Everything else in the file - comments, order, other theme lines -
    /// stays as it was.
    private func write(theme: String) throws {
        // Written through a symlink, not over it: a dotfiles checkout often
        // links this file, and an atomic write would replace the link.
        let url = URL(fileURLWithPath: configPath).resolvingSymlinksInPath()
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let line = "theme = \(theme)"
        if let index = lines.lastIndex(where: { Self.value(of: "theme", in: $0) != nil }) {
            lines[index] = line
        } else {
            // Before the final empty element, so the file keeps ending in a newline.
            if lines.last == "" { lines.insert(line, at: lines.count - 1) } else { lines += [line, ""] }
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func background(of config: Ghostty.Config) -> [UInt8]? {
        guard let cfg = config.config else { return nil }
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(cfg, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return [color.r, color.g, color.b]
    }

    private func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Closing by any route but Save - Cancel, Esc, the close button - puts
    /// the saved theme back.
    func windowWillClose(_ notification: Notification) {
        guard preview != nil else { return }
        preview = nil
        ghostty.reloadConfig()
    }
}

/// A row: the theme's name beside a swatch in its own background and
/// foreground, so a list of names says what each one looks like.
private final class ThemeCellView: NSTableCellView {
    private let swatch = NSTextField(labelWithString: "Ab")
    private let name = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.alignment = .center
        swatch.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        for view in [swatch, name] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = name
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 30),
            swatch.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(name text: String, background: NSColor?, foreground: NSColor?) {
        name.stringValue = text
        swatch.drawsBackground = true
        swatch.backgroundColor = background ?? .textBackgroundColor
        swatch.textColor = foreground ?? .textColor
    }
}
