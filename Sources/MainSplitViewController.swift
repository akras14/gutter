import AppKit
import GhosttyKit
import SwiftUI

/// Window shell: collapsible sidebar on the left, the selected session's panes
/// on the right.
final class MainSplitViewController: NSSplitViewController {
    let sessions: SessionManager
    private let container: TerminalContainerViewController
    private var sidebarVC: SidebarViewController?

    init(sessions: SessionManager, ghostty: Ghostty.App) {
        self.sessions = sessions
        self.container = TerminalContainerViewController(sessions: sessions, ghostty: ghostty)
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

    /// What a new window copies so it opens looking like the one it came from.
    /// Zero while the sidebar is collapsed.
    var sidebarWidth: CGFloat {
        guard let item = splitViewItems.first, !item.isCollapsed else { return 0 }
        return item.viewController.view.frame.width
    }

    func show(_ session: Session?) {
        container.show(session)
    }

    /// A session's panes changed shape - split, closed, zoomed, resized.
    func refresh(_ session: Session) {
        container.refresh(session)
    }
}

/// Hosts the selected session's pane tree, and nothing else.
///
/// The tree is SwiftUI (`SessionTreeView`), which is what makes this small: the
/// find bar, the pointer cursor, surface sizing, scrollbars and the resize
/// overlay all come from the vendored ghostty views inside it rather than from
/// code here. See `SessionTreeView` for the list.
final class TerminalContainerViewController: NSViewController {
    private let sessions: SessionManager
    private let ghostty: Ghostty.App
    private(set) var current: Session?

    init(sessions: SessionManager, ghostty: Ghostty.App) {
        self.sessions = sessions
        self.ghostty = ghostty
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var host: NSHostingView<AnyView> {
        // swiftlint:disable:next force_cast
        view as! NSHostingView<AnyView>
    }

    override func loadView() {
        view = NSHostingView(rootView: AnyView(Color.clear))
    }

    func show(_ session: Session?) {
        guard session !== current else { return }
        current = session
        render()
    }

    func refresh(_ session: Session) {
        guard session === current else { return }
        render()
    }

    private func render() {
        guard let session = current else {
            host.rootView = AnyView(Color.clear)
            return
        }
        host.rootView = AnyView(
            SessionTreeView(tree: session.tree) { [weak self] node, ratio in
                guard let self, let current = self.current else { return }
                self.sessions.setRatio(current, node: node, to: ratio)
            }
            // SurfaceWrapper and InspectableSurface both read the app out of
            // the environment; Gutter has exactly one.
            .environmentObject(ghostty)
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Keyboard split resize converts pixels to a ratio, so the tree needs
        // to know the area it is laid out in. Nothing else here needs a size:
        // each surface gets its own from the GeometryReader in SurfaceWrapper.
        sessions.terminalBounds = view.bounds
    }
}
