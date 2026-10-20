import AppKit

/// The ⌘⇧T sheet: where to run, what to run, and the request itself.
///
/// Built on NSAlert rather than a hand-rolled sheet window. The alert brings
/// the button row and Esc-cancels. Return firing the default button is the
/// point of the whole feature - a request is type-and-enter - so it survives
/// the request box being multi-line (#6): plain Return still starts, and only
/// Shift-Return (or Option-Return) breaks the line. Requests run to several
/// lines - a bug report, a list of steps - and a one-line field showed none of
/// it and dropped the line breaks from a paste.
final class NewRequestSheet: NSObject, NSTextViewDelegate {
    struct Request {
        let command: String
        /// nil when the field was cleared: let the new session inherit.
        let directory: String?
        let prompt: String
    }

    private let launchers: LauncherConfig
    private let alert = NSAlert()
    private let folderPopUp = NSPopUpButton()
    private let toolPopUp = NSPopUpButton()
    private let promptView = PromptTextView()
    private let promptScroll = NSScrollView()

    /// Once the tool is chosen by hand, editing the folder stops re-choosing
    /// it - the folder default is a starting point, not an override.
    private var toolPickedByHand = false

    /// `folders` is the whole list to offer, the one to start on first -
    /// the popup selects its first item, and that is the folder the user is
    /// already in.
    init(launchers: LauncherConfig, folders: [String]) {
        self.launchers = launchers
        super.init()

        alert.messageText = "New Request"
        alert.informativeText = "Runs in a new tab. This one keeps focus."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        // Shown in tilde form - shorter to read, and the shape the launchers
        // file uses - while each item carries the real path to run in.
        for folder in folders {
            let item = NSMenuItem()
            item.title = (folder as NSString).abbreviatingWithTildeInPath
            item.representedObject = folder
            folderPopUp.menu?.addItem(item)
        }
        folderPopUp.target = self
        folderPopUp.action = #selector(folderChanged)
        promptView.placeholder = "What should it do?"
        promptView.delegate = self
        toolPopUp.target = self
        toolPopUp.action = #selector(toolChanged)
        reloadTools()

        alert.accessoryView = accessoryView()
    }

    private func accessoryView() -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 10
        grid.rowSpacing = 8
        // Labels right-aligned against their fields, like the shortcuts panel.
        grid.column(at: 0).xPlacement = .trailing
        for (title, field) in [("Folder:", folderPopUp as NSView),
                               ("Tool:", toolPopUp),
                               ("Request:", promptBox())] {
            grid.addRow(with: [NSTextField(labelWithString: title), field])
        }
        // The label sits at the box's first line, not its middle.
        grid.row(at: 2).yPlacement = .top
        // NSAlert lays its accessory view out from the frame, not constraints.
        grid.setFrameSize(grid.fittingSize)
        return grid
    }

    /// About five lines tall, scrolling past that. A text view doesn't size
    /// itself the way a field does, so the scroll view carries the size.
    private func promptBox() -> NSView {
        promptScroll.borderType = .bezelBorder
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.widthAnchor.constraint(equalToConstant: 340).isActive = true
        promptScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true

        promptView.isRichText = false
        promptView.allowsUndo = true
        promptView.font = .systemFont(ofSize: NSFont.systemFontSize)
        promptView.textContainerInset = NSSize(width: 2, height: 3)
        // Prose, not code: none of the substitutions that would change what
        // reaches the tool.
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.isAutomaticTextReplacementEnabled = false
        promptView.minSize = .zero
        promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        promptView.isVerticallyResizable = true
        promptView.isHorizontallyResizable = false
        promptView.autoresizingMask = [.width]
        promptView.textContainer?.widthTracksTextView = true
        promptScroll.documentView = promptView
        return promptScroll
    }

    /// Return is Start and Esc is Cancel, as they were with a one-line field;
    /// a text view would otherwise insert a newline and run completion. Tab
    /// moves on rather than inserting a tab.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                alert.buttons.first?.performClick(nil)
            }
        case #selector(NSResponder.cancelOperation(_:)):
            alert.buttons.last?.performClick(nil)
        case #selector(NSResponder.insertTab(_:)):
            textView.window?.selectNextKeyView(nil)
        case #selector(NSResponder.insertBacktab(_:)):
            textView.window?.selectPreviousKeyView(nil)
        default:
            return false
        }
        return true
    }

    /// `completion` runs with nil when the sheet is cancelled, so the caller
    /// can drop its reference either way.
    func present(in window: NSWindow?, completion: @escaping (Request?) -> Void) {
        alert.layout()
        // After layout: the accessory view isn't in a window before that.
        alert.window.initialFirstResponder = promptView

        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self, response == .alertFirstButtonReturn else { return completion(nil) }
            completion(self.request())
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func request() -> Request? {
        guard let command = toolPopUp.titleOfSelectedItem else { return nil }
        return Request(command: command, directory: directory(), prompt: promptView.string)
    }

    /// The real path behind the selected item, not its tilde-shortened title.
    private func directory() -> String? {
        folderPopUp.selectedItem?.representedObject as? String
    }

    private func reloadTools() {
        let chosen = toolPickedByHand ? toolPopUp.titleOfSelectedItem : nil
        toolPopUp.removeAllItems()
        // choices(for:) puts the folder's own default first, and a fresh
        // NSPopUpButton selects its first item.
        toolPopUp.addItems(withTitles: launchers.choices(for: directory()))
        if let chosen, toolPopUp.itemTitles.contains(chosen) {
            toolPopUp.selectItem(withTitle: chosen)
        }
    }

    @objc private func toolChanged() {
        toolPickedByHand = true
    }

    @objc private func folderChanged() {
        reloadTools()
    }
}

/// The request box. NSTextView has no public placeholder, so it draws its own.
private final class PromptTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    // Typing the first character has to clear the placeholder, and deleting
    // the last has to bring it back; the text view only redraws the line.
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
