import AppKit

/// The ⌘⇧T sheet: where to run, what to run, and the request itself.
///
/// Built on NSAlert rather than a hand-rolled sheet window. The alert brings
/// the button row, Esc-cancels, and - the point of the whole feature - Return
/// firing the default button, so a request is type-and-enter.
final class NewRequestSheet: NSObject {
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
    private let promptField = NSTextField()

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
        promptField.placeholderString = "What should it do?"
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
                               ("Request:", promptField)] {
            grid.addRow(with: [NSTextField(labelWithString: title), field])
        }
        promptField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        // NSAlert lays its accessory view out from the frame, not constraints.
        grid.setFrameSize(grid.fittingSize)
        return grid
    }

    /// `completion` runs with nil when the sheet is cancelled, so the caller
    /// can drop its reference either way.
    func present(in window: NSWindow?, completion: @escaping (Request?) -> Void) {
        alert.layout()
        // After layout: the accessory view isn't in a window before that.
        alert.window.initialFirstResponder = promptField

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
        return Request(command: command, directory: directory(), prompt: promptField.stringValue)
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
