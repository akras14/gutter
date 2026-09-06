import CoreServices
import Foundation

/// Watches a repo tree and reports what changed, so the diff window can notice
/// that what it is showing has moved on.
///
/// FSEvents, not a poll: the window is open while an agent writes, and asking
/// git on a timer would either miss the change or run git forever. The stream
/// coalesces a burst of writes into one callback (the latency below), which is
/// what makes a busy agent cheap to watch.
///
/// This reports paths and nothing else - whether a path matters to the diff is
/// a git question, and lives in `GitDiff`.
final class RepoWatcher {
    /// Absolute paths from one coalesced batch, on the main queue.
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?
    /// The tree being watched, nil when nothing is. Also the guard against
    /// tearing down and rebuilding the stream for the repo already watched.
    private(set) var root: String?

    init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(root: String) {
        guard root != self.root else { return }
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        // File-level paths, not the directory-level default: the filtering on
        // the other side is per file (a commit's ref log matters, the index
        // git rewrites on every status does not), and a directory path can't
        // be told apart that way.
        let flags = kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes makes this a CFArray of
            // CFStrings rather than the C string array of the default.
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            guard !list.isEmpty else { return }
            watcher.onChange(list)
        }

        // 1s latency: long enough that a file being written line by line
        // arrives as one batch, short enough that the hint follows the edit
        // rather than trailing it. NoDefer sends the first event of an idle
        // period immediately and coalesces the rest.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(flags))
        else { return }

        // Main queue: the callback only hands paths to the window controller,
        // which is main-thread state. The git call it may lead to is the part
        // that goes to a background queue.
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        self.root = root
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        self.root = nil
    }
}
