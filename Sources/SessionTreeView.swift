import SwiftUI

/// One session's panes, drawn with ghostty's own split views.
///
/// This mirrors ghostty's `TerminalSplitTreeView` (`macos/Sources/Features/Splits/`,
/// which `vendor.sh` does not copy) minus its drag-and-drop zones, which Gutter
/// deliberately doesn't have - see `DESIGN.md`. Everything it composes *is*
/// vendored, so panes get a great deal Gutter would otherwise hand-write:
/// `SplitView` brings the divider, its drag and its double-click equalize, and
/// `Ghostty.InspectableSurface` wraps `SurfaceWrapper`, which brings the
/// per-pane find bar (`SurfaceSearchOverlay`), the unfocused-pane dimming,
/// the resize overlay, the progress bar, the bell border, and - through
/// `SurfaceRepresentable` -> `SurfaceScrollView` - the pointer cursor and
/// surface sizing.
///
/// When updating ghostty, diff this against upstream's version.
struct SessionTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>

    /// A divider moved. The tree is immutable, so the change goes back to
    /// `SessionManager` rather than being written here.
    let onResize: (SplitTree<Ghostty.SurfaceView>.Node, Double) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            SessionSubtreeView(node: node, isRoot: node == tree.root, onResize: onResize)
                // SwiftUI's implicit structural identity can't see a tree
                // reshaping underneath it, and upstream hit real misbehavior
                // without this (ghostty-org/ghostty#7546).
                .id(node.structuralIdentity)
        }
    }
}

private struct SessionSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    /// A lone surface is not "split", so it isn't dimmed when focus is elsewhere.
    var isRoot: Bool = false
    let onResize: (SplitTree<Ghostty.SurfaceView>.Node, Double) -> Void

    var body: some View {
        switch node {
        case .leaf(let surfaceView):
            Ghostty.InspectableSurface(surfaceView: surfaceView, isSplit: !isRoot)

        case .split(let split):
            SplitView(
                split.direction == .horizontal ? .horizontal : .vertical,
                .init(get: { CGFloat(split.ratio) },
                      set: { onResize(node, Double($0)) }),
                dividerColor: ghostty.config.splitDividerColor,
                left: { SessionSubtreeView(node: split.left, onResize: onResize) },
                right: { SessionSubtreeView(node: split.right, onResize: onResize) },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                })
        }
    }
}
