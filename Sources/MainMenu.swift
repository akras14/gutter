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
        // Gutter's own config file (~/.config/gutter/config), not ghostty's -
        // ⌘, and ⇧⌘, are the same keys ghostty binds for its config.
        appMenu.addItem(withTitle: "Open Config...",
                        action: #selector(AppDelegate.openConfigFile(_:)), keyEquivalent: ",").target = target
        let reload = appMenu.addItem(withTitle: "Reload Config",
                                     action: #selector(AppDelegate.reloadConfigFile(_:)), keyEquivalent: ",")
        reload.keyEquivalentModifierMask = [.command, .shift]
        reload.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Gutter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Gutter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t").target = target
        let rename = fileMenu.addItem(withTitle: "Rename Tab...",
                                      action: #selector(AppDelegate.renameTab(_:)), keyEquivalent: "R")
        rename.keyEquivalentModifierMask = [.command, .shift]
        rename.target = target
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w").target = target
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let findItem = NSMenuItem()
        findItem.title = "Find"
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(withTitle: "Find...",
                         action: #selector(AppDelegate.findInTerminal(_:)), keyEquivalent: "f").target = target
        findMenu.addItem(withTitle: "Find Next",
                         action: #selector(AppDelegate.findNextMatch(_:)), keyEquivalent: "g").target = target
        let findPrev = findMenu.addItem(withTitle: "Find Previous",
                                        action: #selector(AppDelegate.findPreviousMatch(_:)), keyEquivalent: "G")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.target = target
        findMenu.addItem(withTitle: "Use Selection for Find",
                         action: #selector(AppDelegate.useSelectionForFind(_:)), keyEquivalent: "e").target = target
        findItem.submenu = findMenu
        editMenu.addItem(findItem)
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // cmd-b, matching VS Code and Zed: the sidebar is imitating theirs.
        // Not the ctrl-cmd-s this started with - one binding, and an NSMenuItem
        // holds only one key equivalent anyway.
        viewMenu.addItem(withTitle: "Toggle Sidebar",
                         action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "b")
        // No explicit target: the responder chain delivers this to MainSplitViewController.
        // ctrl-cmd-shift-g would be the obvious pick, but VS Code opens source
        // control with ctrl-shift-g and this window is the same idea; the
        // toolbar button is unreachable in fullscreen, where the bar is hidden.
        let diff = viewMenu.addItem(withTitle: "Show Uncommitted Changes",
                                    action: #selector(AppDelegate.showGitDiff(_:)), keyEquivalent: "g")
        diff.keyEquivalentModifierMask = [.control, .shift]
        diff.target = target
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

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        // ⌘? is the standard macOS help key, and unlike ⌘/ it doesn't take a
        // bare keystroke away from the terminal.
        let shortcuts = helpMenu.addItem(withTitle: "Keyboard Shortcuts",
                                         action: #selector(AppDelegate.showShortcuts(_:)), keyEquivalent: "/")
        shortcuts.keyEquivalentModifierMask = [.command, .shift]
        shortcuts.target = target
        helpItem.submenu = helpMenu

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        // Added last so Help sits at the right end of the bar, and registered
        // with NSApp so the system adds its search field.
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        return main
    }
}
