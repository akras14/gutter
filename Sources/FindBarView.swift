import AppKit
import Combine
import GhosttyKit

/// The find bar: a floating strip over the top-right of the terminal surface.
///
/// libghostty owns the matching engine, so this view never searches anything.
/// It only edits the vendored `SurfaceView.searchState`, and the wrapper turns
/// those edits into keybind actions: writing `needle` fires a debounced
/// `search:<needle>`, clearing `searchState` fires `end_search`. Results come
/// back the same way - libghostty emits `search_total` / `search_selected`
/// actions that the wrapper writes onto the same object. So both directions of
/// this UI are just Combine subscriptions on `SearchState`.
final class FindBarView: NSView, NSTextFieldDelegate {
    let state: Ghostty.SurfaceView.SearchState

    private let surfaceView: Ghostty.SurfaceView
    private let field = NSTextField()
    private let counter = NSTextField(labelWithString: "")
    private var cancellables: Set<AnyCancellable> = []

    init(surfaceView: Ghostty.SurfaceView, state: Ghostty.SurfaceView.SearchState) {
        self.surfaceView = surfaceView
        self.state = state
        super.init(frame: .zero)

        // Shadow on the outer view, rounding on the inner one: a layer can't
        // both clip its corners and cast a shadow outside its bounds.
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = .black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()

        let backing = NSVisualEffectView()
        backing.material = .popover
        backing.blendingMode = .withinWindow
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 8
        backing.layer?.masksToBounds = true
        backing.translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = "Search"
        field.stringValue = state.needle
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        // Live edits, not just on Return: every keystroke should re-search.
        field.isContinuous = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true

        counter.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .right
        counter.setContentHuggingPriority(.defaultLow, for: .horizontal)
        counter.widthAnchor.constraint(equalToConstant: 56).isActive = true

        // Up is "next" and down is "previous", matching ghostty proper: a
        // scrollback search starts at the bottom, so the next match is older.
        let stack = NSStackView(views: [
            field,
            counter,
            iconButton("chevron.up", "Find Next", #selector(next(_:))),
            iconButton("chevron.down", "Find Previous", #selector(previous(_:))),
            iconButton("xmark", "Close Find Bar", #selector(close(_:))),
        ])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        backing.addSubview(stack)
        addSubview(backing)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
            stack.topAnchor.constraint(equalTo: backing.topAnchor),
            stack.bottomAnchor.constraint(equalTo: backing.bottomAnchor),
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        state.$selected
            .combineLatest(state.$total)
            .receive(on: RunLoop.main)
            .sink { [weak self] selected, total in
                self?.updateCounter(selected: selected, total: total)
            }
            .store(in: &cancellables)

        // A second start_search while the bar is already up (the user hits
        // cmd-f again) re-focuses the field rather than reopening anything.
        NotificationCenter.default
            .publisher(for: .ghosttySearchFocus)
            .sink { [weak self] note in
                guard let self, note.object as? Ghostty.SurfaceView === self.surfaceView else { return }
                DispatchQueue.main.async { self.focusField() }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        return button
    }

    private func updateCounter(selected: UInt?, total: UInt?) {
        // libghostty counts matches from zero and reports "no match selected"
        // as nil; the bar reads 1-based, the way every other find bar does.
        let totalText = total.map(String.init) ?? "?"
        if let selected {
            counter.stringValue = "\(selected + 1)/\(totalText)"
        } else if total != nil {
            counter.stringValue = "-/\(totalText)"
        } else {
            counter.stringValue = ""
        }
    }

    // MARK: Focus

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// True while the field editor (or the bar itself) holds first responder.
    /// The container asks before tearing the bar down, so focus can go back to
    /// the terminal instead of dying with the removed view.
    var holdsFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    // MARK: Actions

    @objc private func next(_ sender: Any?) {
        GhosttyBridge.perform("navigate_search:next", on: surfaceView)
    }

    @objc private func previous(_ sender: Any?) {
        GhosttyBridge.perform("navigate_search:previous", on: surfaceView)
    }

    @objc private func close(_ sender: Any?) {
        // Nil-ing the state is the close: the wrapper's didSet fires
        // end_search, and the container tears this view down in response.
        surfaceView.searchState = nil
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        state.needle = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Shift-Return can arrive as either selector depending on the key
            // bindings in play, so read the modifier rather than trust it.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                previous(nil)
            } else {
                next(nil)
            }
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            // Escape with text typed hands focus back to the terminal but keeps
            // the matches highlighted; escape on an empty field closes the bar.
            if state.needle.isEmpty {
                close(nil)
            } else {
                window?.makeFirstResponder(surfaceView)
            }
            return true

        default:
            return false
        }
    }
}
