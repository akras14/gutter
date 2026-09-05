import Foundation

/// Everything that talks to git, plus the line alignment behind the
/// side-by-side view. No AppKit here: `GitDiffWindowController` renders what
/// this produces.
///
/// git is only asked for *file contents* (`git show <rev>:path` and the file on
/// disk), never for a rendered diff - a unified diff can't be laid out in two
/// aligned columns without being un-merged again. The alignment below is a
/// plain LCS over lines, the same shape meld uses.
enum GitDiff {
    /// One changed file in the worktree.
    struct FileChange: Equatable {
        /// Path relative to the repo root, as it exists now.
        let path: String
        /// Where it came from when git detected a rename; nil otherwise.
        let oldPath: String?
        /// git's status letter, plus `?` for untracked.
        let status: Character

        /// What to read from the base rev: a renamed file was there under
        /// its old name.
        var basePath: String { oldPath ?? path }
        var isNew: Bool { status == "A" || status == "?" }
        var isDeleted: Bool { status == "D" }
    }

    struct Row {
        enum Kind: Equatable {
            /// Same line on both sides.
            case equal
            /// Different text on both sides (paired removal + addition).
            case changed
            /// Only on the right.
            case added
            /// Only on the left.
            case removed
        }
        let kind: Kind
        let left: String?
        let right: String?
        let leftNumber: Int?
        let rightNumber: Int?
    }

    /// What one selected file looks like once both sides are loaded.
    enum FileDiff {
        case rows([Row])
        /// Binary, unreadable, or too big to align - shown as a note.
        case note(String)
    }

    // MARK: Repo queries

    struct Repo {
        let root: String
        let branch: String?
    }

    /// nil when `directory` isn't inside a git worktree.
    static func repo(at directory: String) -> Repo? {
        guard case let (root, 0)? = run(["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory).flatMap {
            $0.1 == 0 ? $0.0.trimmed : nil
        }
        return Repo(root: root.trimmed, branch: branch)
    }

    /// Which revision the left pane reads from. The right pane is always the
    /// worktree, so both of these include whatever is still dirty.
    enum Base: Equatable {
        /// HEAD: only what hasn't been committed yet.
        case uncommitted
        /// The merge base with a branch: everything a PR opened right now
        /// would carry, commits on this branch included. Which branch is
        /// `baseline`'s `preferredRef`, or the inferred default.
        case branch
    }

    /// A resolved `Base` - the rev to read file contents from, the ref it came
    /// from, and how to say that in the header.
    struct Baseline {
        let rev: String
        /// The ref itself, for prose that already has "merge base" around it.
        let name: String
        /// What the header says, in the terms the window is actually used to
        /// answer: "is this what my PR will show?". Naming the merge base is
        /// how git describes this comparison, and it sent the one person who
        /// uses Gutter looking for a second merge base to tell it apart from.
        /// The plumbing moved to the tooltip; the header states the outcome.
        let label: String
        /// The merge base itself, short. For the tooltip and the pane caption.
        let shortRev: String
        /// Commits the base ref has gained since the fork - the ones a PR
        /// would not attribute to this branch. Zero on `.uncommitted`.
        let behind: Int
    }

    /// Names to try when `origin/HEAD` is missing, which is common: git only
    /// writes that ref at clone time, so a repo made with `git init` and a
    /// remote added later never has one.
    private static let fallbackRefs = ["origin/main", "origin/master", "main", "master"]

    /// nil when the base can't be worked out - no remote, no default branch,
    /// or histories with no common ancestor. Runs git, so keep it off the main
    /// thread.
    ///
    /// `preferredRef` is the base picked for this repo, if any. It is verified
    /// before use: a branch that has since been deleted or renamed falls back
    /// to the inferred default instead of leaving the window on an error, and
    /// the picker then shows what it fell back to.
    static func baseline(_ base: Base, preferredRef: String? = nil, in directory: String) -> Baseline? {
        switch base {
        case .uncommitted:
            return Baseline(rev: "HEAD", name: "HEAD", label: "vs HEAD",
                            shortRev: "HEAD", behind: 0)
        case .branch:
            guard let ref = verified(preferredRef, in: directory) ?? defaultRef(in: directory)
            else { return nil }
            // merge-base, not the ref itself: a two-dot diff against the tip
            // would also show every commit the default branch gained since we
            // branched, backwards, as deletions we never made.
            guard case let (sha, 0)? = run(["merge-base", ref, "HEAD"], in: directory),
                  !sha.trimmed.isEmpty else { return nil }
            let fork = sha.trimmed
            // How far the base ref has moved on since the fork - the commits a
            // PR into it would not show as this branch's work.
            let behind = run(["rev-list", "--count", "\(fork)..\(ref)"], in: directory)
                .flatMap { $0.1 == 0 ? Int($0.0.trimmed) : nil } ?? 0
            return Baseline(rev: fork, name: ref, label: "PR into \(ref)",
                            shortRev: String(fork.prefix(7)), behind: behind)
        }
    }

    /// Refs worth offering as a branch base: the inferred default first, then
    /// every other branch, most recently committed to first - the branch you
    /// would stack on is one you were just working on.
    ///
    /// The current branch is left out: its merge base with itself is itself,
    /// so the diff would always be empty. So is `origin/HEAD`, a symref alias
    /// for the default that would otherwise appear twice under two names.
    /// Runs git, so keep it off the main thread.
    ///
    /// Asks for full refnames rather than `%(refname:short)`, because the short
    /// form of `refs/remotes/origin/HEAD` is bare `origin` - which no suffix
    /// test recognizes as the alias it is. Shortening here is a prefix strip,
    /// which is all the two namespaces below need.
    static func candidateRefs(in directory: String) -> [String] {
        let current = run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            .flatMap { $0.1 == 0 ? $0.0.trimmed : nil }

        var refs: [String] = []
        var seen = Set<String>()
        func add(_ ref: String) {
            guard !ref.isEmpty, ref != current, seen.insert(ref).inserted else { return }
            refs.append(ref)
        }

        if let ref = defaultRef(in: directory) { add(ref) }
        if case let (out, 0)? = run(["for-each-ref", "--sort=-committerdate",
                                     "--format=%(refname)", "refs/heads", "refs/remotes"],
                                    in: directory) {
            for line in out.split(separator: "\n") {
                let full = String(line).trimmed
                guard !full.hasSuffix("/HEAD") else { continue }
                for prefix in ["refs/heads/", "refs/remotes/"] where full.hasPrefix(prefix) {
                    add(String(full.dropFirst(prefix.count)))
                }
                if refs.count >= candidateRefLimit { break }
            }
        }
        return refs
    }

    /// A repo that has been alive for years has hundreds of refs, and a menu
    /// that long is a list, not a picker. The sort puts the useful ones first,
    /// so the tail is what gets cut.
    private static let candidateRefLimit = 40

    private static func verified(_ ref: String?, in directory: String) -> String? {
        guard let ref, !ref.isEmpty,
              run(["rev-parse", "--verify", "--quiet", ref], in: directory)?.1 == 0
        else { return nil }
        return ref
    }

    private static func defaultRef(in directory: String) -> String? {
        if case let (ref, 0)? = run(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"],
                                    in: directory), !ref.trimmed.isEmpty {
            return ref.trimmed
        }
        return fallbackRefs.first {
            run(["rev-parse", "--verify", "--quiet", $0], in: directory)?.1 == 0
        }
    }

    /// Everything between `rev` and the worktree: staged + unstaged changes,
    /// plus untracked files.""" Sorted by path, deduplicated (a file that is both
    /// staged and dirty shows up once - both states are already folded into the
    /// worktree-vs-HEAD comparison the panes do).
    static func changes(in directory: String, since rev: String) -> [FileChange] {
        var byPath: [String: FileChange] = [:]

        // -M finds renames; -z keeps paths with spaces or quotes intact, which
        // the default C-style quoting would mangle.
        if case let (out, 0)? = run(["diff", rev, "--name-status", "-M", "-z"], in: directory) {
            let fields = out.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            var i = 0
            while i < fields.count {
                let code = fields[i]
                guard let letter = code.first, !code.isEmpty else { break }
                // A rename entry is three fields: "R100", old path, new path.
                if letter == "R" || letter == "C" {
                    guard i + 2 < fields.count else { break }
                    let change = FileChange(path: fields[i + 2], oldPath: fields[i + 1], status: letter)
                    byPath[change.path] = change
                    i += 3
                } else {
                    guard i + 1 < fields.count else { break }
                    let change = FileChange(path: fields[i + 1], oldPath: nil, status: letter)
                    byPath[change.path] = change
                    i += 2
                }
            }
        }

        if case let (out, 0)? = run(["ls-files", "--others", "--exclude-standard", "-z"], in: directory) {
            for path in out.split(separator: "\0").map(String.init) where byPath[path] == nil {
                byPath[path] = FileChange(path: path, oldPath: nil, status: "?")
            }
        }

        return byPath.values.sorted { $0.path < $1.path }
    }

    /// Both sides of one file, aligned into rows. Runs git, so keep it off the
    /// main thread.
    static func diff(_ change: FileChange, in directory: String, since rev: String) -> FileDiff {
        let old: String
        if change.isNew {
            old = ""
        } else {
            guard case let (text, 0)? = runRaw(["show", "\(rev):\(change.basePath)"], in: directory) else {
                return .note("Could not read \(change.basePath) from \(rev).")
            }
            guard let decoded = String(data: text, encoding: .utf8) else {
                return .note("Binary file.")
            }
            old = decoded
        }

        let new: String
        if change.isDeleted {
            new = ""
        } else {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(change.path)
            guard let data = try? Data(contentsOf: url) else {
                return .note("Could not read \(change.path) from the worktree.")
            }
            guard let decoded = String(data: data, encoding: .utf8) else {
                return .note("Binary file.")
            }
            new = decoded
        }

        if old == new { return .note("No differences in file contents.") }
        return .rows(align(lines(old), lines(new)))
    }

    private static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        // A trailing newline ends the last line; it doesn't start an empty one.
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: Alignment

    /// Cap on the LCS table (rows x columns). Past it the differing middle is
    /// shown as one replaced block instead: still correct, just coarser, and it
    /// keeps a 50k-line file from allocating gigabytes.
    private static let lcsCellLimit = 4_000_000

    static func align(_ old: [String], _ new: [String]) -> [Row] {
        // Identical head and tail are the common case in a diff; peeling them
        // off first is what keeps the LCS table small enough to allocate.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let midOld = Array(old[prefix..<(old.count - suffix)])
        let midNew = Array(new[prefix..<(new.count - suffix)])

        var rows: [Row] = []
        for i in 0..<prefix {
            rows.append(Row(kind: .equal, left: old[i], right: new[i],
                            leftNumber: i + 1, rightNumber: i + 1))
        }

        var leftNo = prefix + 1
        var rightNo = prefix + 1
        let middle: [Row]
        if midOld.count * midNew.count > lcsCellLimit {
            middle = pair(removed: midOld, added: midNew, leftNo: &leftNo, rightNo: &rightNo)
        } else {
            middle = alignMiddle(midOld, midNew, leftNo: &leftNo, rightNo: &rightNo)
        }
        rows.append(contentsOf: middle)

        for i in 0..<suffix {
            let l = old.count - suffix + i
            let r = new.count - suffix + i
            rows.append(Row(kind: .equal, left: old[l], right: new[r],
                            leftNumber: l + 1, rightNumber: r + 1))
        }
        return rows
    }

    /// Classic LCS backtrack, then adjacent removals and additions are paired
    /// into `.changed` rows so both sides of an edit sit on the same line.
    private static func alignMiddle(_ old: [String], _ new: [String],
                                    leftNo: inout Int, rightNo: inout Int) -> [Row] {
        let n = old.count, m = new.count
        if n == 0 || m == 0 {
            return pair(removed: old, added: new, leftNo: &leftNo, rightNo: &rightNo)
        }

        // Flat (n+1) x (m+1) table: table[i * span + j].
        let span = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * span)
        // Filled from the bottom-right corner, so the backtrack below can walk forward.
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    table[i * span + j] = table[(i + 1) * span + (j + 1)] + 1
                } else {
                    table[i * span + j] = max(table[(i + 1) * span + j], table[i * span + (j + 1)])
                }
            }
        }

        var rows: [Row] = []
        var pendingRemoved: [String] = []
        var pendingAdded: [String] = []
        func flush() {
            guard !pendingRemoved.isEmpty || !pendingAdded.isEmpty else { return }
            rows.append(contentsOf: pair(removed: pendingRemoved, added: pendingAdded,
                                         leftNo: &leftNo, rightNo: &rightNo))
            pendingRemoved.removeAll()
            pendingAdded.removeAll()
        }

        var i = 0, j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                flush()
                rows.append(Row(kind: .equal, left: old[i], right: new[j],
                                leftNumber: leftNo, rightNumber: rightNo))
                leftNo += 1; rightNo += 1
                i += 1; j += 1
            } else if table[(i + 1) * span + j] >= table[i * span + (j + 1)] {
                pendingRemoved.append(old[i])
                i += 1
            } else {
                pendingAdded.append(new[j])
                j += 1
            }
        }
        while i < n { pendingRemoved.append(old[i]); i += 1 }
        while j < m { pendingAdded.append(new[j]); j += 1 }
        flush()
        return rows
    }

    /// One run of removals and one of additions, side by side: the overlap
    /// becomes `.changed` rows, the remainder gets a blank counterpart.
    private static func pair(removed: [String], added: [String],
                             leftNo: inout Int, rightNo: inout Int) -> [Row] {
        var rows: [Row] = []
        let shared = min(removed.count, added.count)
        for k in 0..<shared {
            rows.append(Row(kind: .changed, left: removed[k], right: added[k],
                            leftNumber: leftNo, rightNumber: rightNo))
            leftNo += 1; rightNo += 1
        }
        for k in shared..<removed.count {
            rows.append(Row(kind: .removed, left: removed[k], right: nil,
                            leftNumber: leftNo, rightNumber: nil))
            leftNo += 1
        }
        for k in shared..<added.count {
            rows.append(Row(kind: .added, left: nil, right: added[k],
                            leftNumber: nil, rightNumber: rightNo))
            rightNo += 1
        }
        return rows
    }

    /// The differing span inside a `.changed` pair, as UTF-16 offsets for
    /// NSAttributedString: everything between the common prefix and the common
    /// suffix. Nil when the two lines share nothing worth narrowing down.
    static func intralineRanges(_ left: String, _ right: String) -> (NSRange, NSRange)? {
        let l = Array(left.utf16), r = Array(right.utf16)
        var head = 0
        while head < l.count, head < r.count, l[head] == r[head] { head += 1 }
        var tail = 0
        while tail < l.count - head, tail < r.count - head,
              l[l.count - 1 - tail] == r[r.count - 1 - tail] { tail += 1 }
        let leftLen = l.count - head - tail
        let rightLen = r.count - head - tail
        // Nothing in common: highlighting the whole line adds no information.
        if head == 0 && tail == 0 { return nil }
        return (NSRange(location: head, length: leftLen), NSRange(location: head, length: rightLen))
    }

    // MARK: Process

    /// (stdout, exit status), or nil if git could not be launched. stderr is
    /// dropped: every failure here is reported through the status.
    static func run(_ args: [String], in directory: String) -> (String, Int32)? {
        guard let (data, status) = runRaw(args, in: directory) else { return nil }
        return (String(data: data, encoding: .utf8) ?? "", status)
    }

    static func runRaw(_ args: [String], in directory: String) -> (Data, Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a pipe that fills up blocks git forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
