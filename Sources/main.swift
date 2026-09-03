import AppKit
import Foundation
import GhosttyKit

// libghostty resolves bundled resources (themes, shell-integration) via
// GHOSTTY_RESOURCES_DIR; point it at the app bundle's copy.
if let res = Bundle.main.resourceURL {
    setenv("GHOSTTY_RESOURCES_DIR", res.appendingPathComponent("ghostty").path, 1)
}

// Initialize libghostty global state before anything else touches the API.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    FileHandle.standardError.write("ghostty_init failed\n".data(using: .utf8)!)
    exit(1)
}

// Embedder config overrides, loaded after the user's own config. The core
// has no default cmd+t=new_tab on macOS (upstream handles it in their app
// menu) and only binds goto_tab 1-8; add what the sidebar needs.
// The two comma binds go the other way: the core binds super+, to open_config
// and super+shift+, to reload_config, the surface swallows them before the
// menu bar ever sees the key, and the vendored handler for open_config opens
// ghostty's own default config path through NSWorkspace - which on this file
// type only produces a "no application set to open the document" panel.
// Unbind both so Gutter's own menu items (AppDelegate.openConfigFile /
// reloadConfigFile) get the keystrokes.
// super+shift+t is the same story: with a focused surface the core claimed the
// key and File > New Request never fired, while the same keystroke worked with
// the sidebar focused. Unbinding hands it to the menu from either place.
// NOTE: don't override `command` here - repeated command keys append to the
// default argv instead of replacing it.
do {
    let overrides = """
    keybind = super+t=new_tab
    keybind = super+9=goto_tab:9
    keybind = super+,=unbind
    keybind = super+shift+,=unbind
    keybind = super+shift+t=unbind
    """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-tabs-overrides.conf")
    try overrides.write(to: url, atomically: true, encoding: .utf8)
    Ghostty.Config.embedderConfigFile = url.path
} catch {
    FileHandle.standardError.write("warning: could not write config overrides: \(error)\n".data(using: .utf8)!)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
