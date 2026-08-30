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
// NOTE: don't override `command` here - repeated command keys append to the
// default argv instead of replacing it.
do {
    let overrides = """
    keybind = super+t=new_tab
    keybind = super+9=goto_tab:9
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
