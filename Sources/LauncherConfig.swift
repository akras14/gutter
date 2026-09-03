import Foundation

/// Gutter's own config file: the commands a new session can be started with,
/// and which folders prefer which.
///
/// Deliberately not `~/.config/gutter/config`. That file is parsed by
/// libghostty, which diagnoses keys it doesn't recognize, so Gutter can't add
/// its own there. The syntax is the same `key = value` shape so the two files
/// read alike:
///
///     launcher = claude
///     launcher = pclaude
///     launcher-for ~/projects = pclaude
///
/// The command is also the label - `pclaude` says what it is, and a separate
/// name per launcher would be one more thing to keep in sync.
struct LauncherConfig {
    static let path = ("~/.config/gutter/launchers" as NSString).expandingTildeInPath

    /// Commands in file order. The first is the default when no folder matches.
    private(set) var commands: [String] = []

    /// Folder prefix -> command. Longest matching prefix wins, so a rule for
    /// `~/src/screenings_app` beats one for `~/src`.
    private(set) var folderDefaults: [(prefix: String, command: String)] = []

    /// Folders to offer in the sheet on top of the ones tabs are already open
    /// in - a project you come back to but don't always have a tab in.
    private(set) var folders: [String] = []

    /// The command a session in `directory` should start with. Falls back to
    /// the first launcher, and to nil when the file has none.
    func command(for directory: String?) -> String? {
        if let directory = directory.map(Self.expand) {
            let match = folderDefaults
                .filter { directory == $0.prefix || directory.hasPrefix($0.prefix + "/") }
                .max { $0.prefix.count < $1.prefix.count }
            if let match { return match.command }
        }
        return commands.first
    }

    /// Every command worth offering for `directory`, the preferred one first.
    /// A `launcher-for` may name a command that isn't in the `launcher` list;
    /// it still belongs in the menu, or the folder's own default would be
    /// unpickable.
    func choices(for directory: String?) -> [String] {
        guard let preferred = command(for: directory) else { return [] }
        return [preferred] + commands.filter { $0 != preferred }
    }

    static func load() -> LauncherConfig {
        parse(try? String(contentsOfFile: path, encoding: .utf8))
    }

    /// Blank lines and `#` comments are skipped; so is any line Gutter doesn't
    /// recognize. Unlike libghostty this file has no error reporting to hang a
    /// diagnostic on, and a typo silently doing nothing beats a modal on launch.
    static func parse(_ text: String?) -> LauncherConfig {
        var config = LauncherConfig()
        for raw in (text ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            if key == "launcher" {
                config.commands.append(value)
            } else if key == "folder" {
                config.folders.append(expand(value))
            } else if key.hasPrefix("launcher-for") {
                // The path is part of the key: `launcher-for ~/projects = pclaude`.
                // Splitting on the first `=` keeps a command with an `=` in it intact.
                let path = key.dropFirst("launcher-for".count).trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                config.folderDefaults.append((expand(path), value))
            }
        }
        return config
    }

    /// What to type into the new session's shell. The prompt goes in as one
    /// single-quoted argument: it is the user's prose, so apostrophes, quotes
    /// and `$` in it must never reach the shell as syntax.
    static func commandLine(_ command: String, prompt: String) -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return command + "\n" }
        return "\(command) \(singleQuoted(prompt))\n"
    }

    /// sh single-quoting: end the quote, escape the apostrophe, reopen it.
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func expand(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// Writes a commented template on first use. All comments, so it configures
    /// nothing by itself - but unlike the ghostty config, an empty file here
    /// would leave no clue what the file is for.
    static func ensureFile() {
        let url = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let template = """
        # Gutter launchers: the commands a new request can start.
        #
        # Gutter's own file. Ghostty parses ~/.config/gutter/config and rejects
        # keys it doesn't know, so these can't live there.
        #
        # One command per line. The first is the default.
        #
        #   launcher = claude
        #   launcher = pclaude
        #
        # Give a folder tree its own default. Longest matching path wins.
        #
        #   launcher-for ~/projects = pclaude
        #
        # Folders to offer besides the ones your tabs are already in.
        #
        #   folder = ~/src/screenings_app
        #
        # Commands run in your interactive shell, so aliases work.

        """
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }
}
