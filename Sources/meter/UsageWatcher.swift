import Foundation
import CoreServices

/// FSEvents watcher over the local usage logs. A refresh compares `generation`
/// with the one from its last scan and skips the log pass entirely when nothing
/// has been written since; one-shot CLI modes never touch this.
///
/// Only files a scan actually reads count as changes: the CLIs write logs,
/// caches, crash reports and updater state under the same roots, and those must
/// not trigger a scan.
final class UsageWatcher {
    static let shared = UsageWatcher(roots: CostScan.watchRoots())

    private let roots: [String]
    private let queue = DispatchQueue(label: "meter.usage-watcher")
    private let lock = NSLock()
    private var generationValue: UInt64 = 0
    private var stream: FSEventStreamRef?

    /// The shared instance lives for the process; callers only read state.
    init(roots: [String]) {
        self.roots = roots
        start()
    }

    /// False when the stream could not start (e.g. no roots exist yet), in which
    /// case the caller must scan on every refresh.
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generationValue
    }

    // MARK: - filtering

    /// Files the cost scans read. Everything else under a watched root is noise
    /// (`log/cli-*.log`, `crashes/*`, `updater/*`, `cache/onboarding.json`, …).
    func isUsageFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if path.contains("/antigravity-cli/") {
            // transcripts and conversation stores; not history/settings/logs
            let usage = (path.contains("/brain/") || path.contains("/conversations/"))
                && (name.hasSuffix(".jsonl") || name.hasSuffix(".db")
                    || name.hasSuffix(".db-wal") || name.hasSuffix(".db-shm"))
            return usage || name == "conversation_summaries.db"
                || name.hasPrefix("conversation_summaries.db-")
        }
        if name.hasSuffix(".jsonl") { return true }
        return name == "opencode.db" || name.hasPrefix("opencode.db-")
    }

    private func bump() {
        lock.lock()
        generationValue &+= 1
        lock.unlock()
    }

    // MARK: - stream lifecycle

    private func start() {
        guard !roots.isEmpty else { return }
        // passUnretained is safe because `shared` is a static let; do not create
        // short-lived instances without stopping the stream first
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<UsageWatcher>.fromOpaque(info).takeUnretainedValue()
            let flags = UnsafeBufferPointer(start: eventFlags, count: count)
            if flags.contains(where: { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 }) {
                watcher.bump()
                return
            }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]
            guard let paths, !paths.isEmpty else { return }
            if paths.contains(where: watcher.isUsageFile) { watcher.bump() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        lock.lock()
        self.stream = stream
        lock.unlock()
    }

    /// Only used by tests; the shared instance is never stopped.
    func stop() {
        lock.lock()
        let stream = stream
        self.stream = nil
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
