import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct SessionDiscoveryTests {
    private func makeFakeHome() throws -> ClaudePaths {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-\(UUID().uuidString)")
        let paths = ClaudePaths(home: home)
        try FileManager.default.createDirectory(
            at: paths.projectsDir, withIntermediateDirectories: true)
        return paths
    }

    private func addTranscript(
        _ paths: ClaudePaths, slug: String, sessionId: String, modifiedAt: Date
    ) throws {
        let fm = FileManager.default
        let dir = paths.projectDir(slug: slug)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionId).jsonl")
        try Data("{\"type\":\"user\"}\n".utf8).write(to: url)
        try fm.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    @Test func projectsSortNewestFirstAndSkipEmpties() throws {
        let paths = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: paths.home) }

        let now = Date()
        try addTranscript(paths, slug: "-old-project", sessionId: "s1", modifiedAt: now - 3600)
        try addTranscript(paths, slug: "-hot-project", sessionId: "s2", modifiedAt: now - 60)
        try addTranscript(paths, slug: "-hot-project", sessionId: "s3", modifiedAt: now - 10)
        try FileManager.default.createDirectory(
            at: paths.projectDir(slug: "-empty-project"), withIntermediateDirectories: true)

        let projects = SessionDiscovery(paths: paths).projects()
        #expect(projects.map(\.slug) == ["-hot-project", "-old-project"])
        #expect(projects[0].transcripts.map(\.sessionId) == ["s3", "s2"])
        #expect(projects[0].transcripts[0].size > 0)
    }

    @Test func missingProjectsDirYieldsEmpty() {
        let paths = ClaudePaths(home: URL(filePath: "/nonexistent/claude-home"))
        #expect(SessionDiscovery(paths: paths).projects().isEmpty)
    }
}

@Suite struct FSEventsWatcherTests {
    @Test func firesOnFileCreation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fired = DispatchSemaphore(value: 0)
        let watcher = FSEventsWatcher(paths: [dir.path], latency: 0.05) { _ in
            fired.signal()
        }
        defer { watcher?.stop() }
        #expect(watcher != nil)

        // Give the stream a beat to start before generating the event.
        Thread.sleep(forTimeInterval: 0.2)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("new.jsonl"))

        #expect(fired.wait(timeout: .now() + 5) == .success)
    }

    /// Closing a window drops a watcher while its directory is still being
    /// written, and a callback can be mid-flight when it goes. Teardown
    /// must wait for that callback rather than free the handler underneath
    /// it — asserted by the clock here, and by ASan on the freeing itself
    /// (`swift test --sanitize=address`).
    @Test func teardownWaitsForAnInFlightCallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-teardown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let entered = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var running = 0
        var finished = 0
        let watcher = FSEventsWatcher(paths: [dir.path], latency: 0.01) { _ in
            lock.lock()
            running += 1
            lock.unlock()
            entered.signal()
            Thread.sleep(forTimeInterval: 0.3)
            lock.lock()
            finished += 1
            lock.unlock()
        }
        #expect(watcher != nil)

        Thread.sleep(forTimeInterval: 0.2)  // let the stream start
        try Data("hello".utf8).write(to: dir.appendingPathComponent("new.jsonl"))
        #expect(entered.wait(timeout: .now() + 5) == .success)

        // Assert the fact rather than a duration: however slow or fast this
        // machine is, every callback that started must have finished by the
        // time stop() returns, or the release freed the handler under one.
        watcher?.stop()

        lock.lock()
        let (started, done) = (running, finished)
        lock.unlock()
        #expect(started > 0, "no callback was in flight — the test proved nothing")
        #expect(
            done == started,
            "stop() returned with \(started - done) of \(started) callbacks still running")
    }

    /// "Stop watching once I have seen what I came for" is the natural way
    /// to write a one-shot watcher, and it aborted the process: stop()
    /// waited on the queue it was already running on, which libdispatch
    /// answers with a trap rather than a hang.
    @Test func stoppingFromInsideACallbackDoesNotTrap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-reentrant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        final class Box: @unchecked Sendable {
            var watcher: FSEventsWatcher?
        }
        let box = Box()
        let stopped = DispatchSemaphore(value: 0)
        box.watcher = FSEventsWatcher(paths: [dir.path], latency: 0.01) { _ in
            box.watcher?.stop()
            stopped.signal()
        }
        #expect(box.watcher != nil)

        Thread.sleep(forTimeInterval: 0.2)  // let the stream start
        try Data("hello".utf8).write(to: dir.appendingPathComponent("new.jsonl"))
        #expect(stopped.wait(timeout: .now() + 5) == .success)

        // And a second stop from outside is a no-op rather than a double
        // release: the check-and-clear is under a lock now.
        box.watcher?.stop()
    }
}
