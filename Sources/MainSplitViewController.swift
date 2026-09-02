import AppKit
import Combine
import GhosttyKit

/// Window shell: collapsible sidebar on the left, terminal surface on the right.
final class MainSplitViewController: NSSplitViewController {
    let sessions: SessionManager
    private let container = TerminalContainerViewController()
    private var sidebarVC: SidebarViewController?

    init(sessions: SessionManager) {
        self.sessions = sessions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: SidebarViewController(sessions: sessions))
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 480
        sidebarItem.canCollapse = true
        sidebarVC = sidebarItem.viewController as? SidebarViewController
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 400
        addSplitViewItem(contentItem)
    }

    func sidebarReload() {
        sidebarVC?.reload()
    }

    /// Renaming edits a sidebar row, so the sidebar has to be on screen.
    func beginRenameSelectedTab() {
        if let sidebarItem = splitViewItems.first, sidebarItem.isCollapsed {
            sidebarItem.isCollapsed = false
        }
        sidebarVC?.beginRenameSelected()
    }

    func setSidebarWidth(_ width: CGFloat) {
        splitView.setPosition(width, ofDividerAt: 0)
    }

    func show(_ session: Session?) {
        container.show(session)
    }
}

/// Hosts exactly the selected session's SurfaceView, pinned edge to edge,
/// with the find bar floating over its top-right corner.
final class TerminalContainerViewController: NSViewController {
    private(set) var current: Session?
    private var findBar: FindBarView?
    private var searchCancellable: AnyCancellable?
    private var pointerCancellable: AnyCancellable?

    override func loadView() {
        view = TerminalHostView()
        view.wantsLayer = true
    }

    func show(_ session: Session?) {
        guard session !== current else { return }
        current?.view.removeFromSuperview()
        removeFindBar()
        searchCancellable = nil
        pointerCancellable = nil
        current = session

        guard let v = session?.view else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // libghostty reports the pointer shape (I-beam over text, pointing hand
        // over a link) as a published property on the surface; nothing applies
        // it. Ghostty's own host is an NSScrollView and uses documentCursor -
        // this container is the same idea one level up, a cursor rect over the
        // whole terminal area.
        pointerCancellable = v.$pointerStyle
            .receive(on: RunLoop.main)
            .sink { [weak self, weak v] style in
                guard let self, let v, self.current?.view === v else { return }
                (self.view as? TerminalHostView)?.cursor = style.cursor
            }

        // The surface, not this controller, decides when the find bar exists:
        // both the Find menu and ghostty's own start_search keybind end up
        // setting searchState, and end_search clears it. Subscribing also
        // restores an open bar when the user switches back to this session,
        // since the state hangs off the SurfaceView.
        searchCancellable = v.$searchState
            .receive(on: RunLoop.main)
            .sink { [weak self, weak v] state in
                guard let self, let v, self.current?.view === v else { return }
                if let state {
                    self.showFindBar(state, on: v)
                } else {
                    self.removeFindBar()
                }
            }
    }

    private func showFindBar(_ state: Ghostty.SurfaceView.SearchState, on surface: Ghostty.SurfaceView) {
        if let bar = findBar, bar.state === state {
            bar.focusField()
            return
        }
        removeFindBar()

        let bar = FindBarView(surfaceView: surface, state: state)
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
        findBar = bar
        bar.focusField()
    }

    private func removeFindBar() {
        guard let bar = findBar else { return }
        findBar = nil
        // Hand focus back before the view goes away, or the window is left with
        // a dead field editor as first responder and keystrokes fall on the
        // floor until the user clicks the terminal.
        let hadFocus = bar.holdsFocus
        bar.removeFromSuperview()
        if hadFocus, let v = current?.view {
            view.window?.makeFirstResponder(v)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Same contract as ghostty's SurfaceScrollView: the PTY/renderer needs
        // to know the visible size. Skip zero sizes (pre-window layout).
        if let v = current?.view, v.bounds.width > 0, v.bounds.height > 0 {
            v.sizeDidChange(v.bounds.size)
        }
    }
}

/// The terminal's backdrop. It exists to own a cursor rect: the SurfaceView sets
/// no cursor of its own, so without this the pointer stays an arrow everywhere.
/// A superview's cursor rect still covers the area its subviews sit on - the same
/// arrangement NSClipView uses for documentCursor.
final class TerminalHostView: NSView {
    var cursor: NSCursor = .iBeam {
        didSet {
            guard cursor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }
}
