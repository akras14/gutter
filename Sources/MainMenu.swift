import AppKit

/// Main menu construction. All actionable items target the AppDelegate (menu
/// actions live there); system items target their standard responders.
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Gutter",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Gutter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Gutter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t").target = target
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w").target = target
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let sidebar = viewMenu.addItem(withTitle: "Toggle Sidebar",
                                       action: #selector(AppDelegate.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        sidebar.target = target
        viewMenu.addItem(.separator())
        for i in 1...9 {
            let item = viewMenu.addItem(withTitle: "Select Tab \(i)",
                                        action: #selector(AppDelegate.selectTab(_:)), keyEquivalent: "\(i)")
            item.tag = i - 1
            item.target = target
        }
        viewMenu.addItem(.separator())
        let next = viewMenu.addItem(withTitle: "Show Next Tab",
                                    action: #selector(AppDelegate.nextTab(_:)), keyEquivalent: "\t")
        next.keyEquivalentModifierMask = [.control]
        next.target = target
        let prev = viewMenu.addItem(withTitle: "Show Previous Tab",
                                    action: #selector(AppDelegate.previousTab(_:)), keyEquivalent: "\t")
        prev.keyEquivalentModifierMask = [.control, .shift]
        prev.target = target
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }
}
