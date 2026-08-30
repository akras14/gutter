import AppKit
import SwiftUI

// Swift-overlay-only APIs that are absent when compiling with the
// CommandLineTools toolchain (it ships no Swift overlays). If these become
// available after switching to Xcode's toolchain, delete this file.
extension NSWorkspace {
    func defaultApplicationURL(forExtension ext: String) -> URL? { nil }
    var defaultTextEditor: URL? { nil }
}

// UUID(CFUUID) is overlay-only in Foundation.
extension UUID {
    init(_ cfuuid: CFUUID) {
        let b = CFUUIDGetUUIDBytes(cfuuid)
        let t = uuid_t(
            b.byte0, b.byte1, b.byte2, b.byte3,
            b.byte4, b.byte5, b.byte6, b.byte7,
            b.byte8, b.byte9, b.byte10, b.byte11,
            b.byte12, b.byte13, b.byte14, b.byte15)
        self.init(uuid: t)
    }
}

// SwiftUI.KeyboardShortcut: CustomStringConvertible is overlay-only too; its
// absence made the type-checker diverge on ForEach expressions using it.
extension KeyboardShortcut: CustomStringConvertible {
    public var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += key.character.lowercased()
        return s
    }
}
