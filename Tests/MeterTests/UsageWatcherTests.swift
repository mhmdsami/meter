import XCTest
@testable import meter

final class UsageWatcherTests: XCTestCase {
    /// Keep test watchers alive: the FSEvents context holds an unretained pointer.
    private static var watchers: [UsageWatcher] = []

    func testGenerationBumpsWhenAFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meter-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = UsageWatcher(roots: [dir.resolvingSymlinksInPath().path])
        Self.watchers.append(watcher)
        XCTAssertTrue(watcher.isActive)
        let before = watcher.generation

        try "x\n".write(to: dir.appendingPathComponent("session.jsonl"),
                        atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(10)
        while watcher.generation == before, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThan(watcher.generation, before)
        watcher.stop()
    }

    func testWatchRootsCoverLocalSources() {
        let roots = CostScan.watchRoots()
        for expected in [".codex/sessions", ".local/share/opencode",
                         ".gemini/antigravity-cli", ".pi/agent/sessions"] {
            XCTAssertTrue(roots.contains { $0.hasSuffix(expected) }, "missing \(expected)")
        }
    }

    func testOnlyUsageFilesCountAsChanges() {
        let watcher = UsageWatcher(roots: [])
        XCTAssertTrue(watcher.isUsageFile("/h/.codex/sessions/2026/10/27/rollout.jsonl"))
        XCTAssertTrue(watcher.isUsageFile("/h/.local/share/opencode/opencode.db-wal"))
        XCTAssertTrue(watcher.isUsageFile(
            "/h/.gemini/antigravity-cli/brain/id/.system_generated/logs/transcript.jsonl"))
        XCTAssertTrue(watcher.isUsageFile("/h/.gemini/antigravity-cli/conversations/a.db"))
        XCTAssertTrue(watcher.isUsageFile("/h/.gemini/antigravity-cli/conversation_summaries.db-wal"))
        XCTAssertTrue(watcher.isUsageFile("/h/.fx/usage.jsonl"))

        XCTAssertFalse(watcher.isUsageFile("/h/.gemini/antigravity-cli/log/cli-1.log"))
        XCTAssertFalse(watcher.isUsageFile("/h/.gemini/antigravity-cli/last_check.timestamp"))
        XCTAssertFalse(watcher.isUsageFile("/h/.gemini/antigravity-cli/history.jsonl"))
        XCTAssertFalse(watcher.isUsageFile("/h/.gemini/antigravity-cli/cache/onboarding.json"))
        XCTAssertFalse(watcher.isUsageFile("/h/.local/share/opencode/snapshot/ab/index"))
        XCTAssertFalse(watcher.isUsageFile("/h/.codex/logs_2.sqlite-wal"))
    }
}
