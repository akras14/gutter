import AppKit
import GhosttyKit

/// Window shell: collapsible sidebar on the left, terminal surface on the right.
/// Also hosts the responder-chain actions the menu items target.
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
        sidebarItem.maximumThickness = 320
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

    func show(_ session: Session?) {
        container.show(session)
    }

    // MARK: Responder-chain actions (menu items use nil targets)

    @IBAction func newTab(_ sender: Any?) {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        sessions.newSession(app: app)
    }

    @IBAction func closeTab(_ sender: Any?) {
        sessions.closeSelected()
    }

    @IBAction func selectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        sessions.select(index: item.tag)
    }

    @IBAction func nextTab(_ sender: Any?) {
        sessions.cycle(1)
    }

    @IBAction func previousTab(_ sender: Any?) {
        sessions.cycle(-1)
    }
}

/// Hosts exactly the selected session's SurfaceView, pinned edge to edge.
final class TerminalContainerViewController: NSViewController {
    private(set) var current: Session?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    func show(_ session: Session?) {
        guard session !== current else { return }
        current?.view.removeFromSuperview()
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
