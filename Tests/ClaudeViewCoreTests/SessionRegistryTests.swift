import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct SessionRegistryTests {
    /// Fixture mirroring a real registry entry (v2.1.221), scrubbed.
    /// `stamp` is when the session last said anything. Left alone it is a
    /// fixed date in the past, which is what the field-parsing tests want;
    /// a liveness test has to pass something the running pid could
    /// plausibly have written, since a pid older than its own entry is the
    /// signature of a reused one.
    private func registryJSON(
        pid: Int32, sessionId: String = "sess-1", stamp: Date? = nil
    ) -> String {
        let started = stamp.map { $0.timeIntervalSince1970 * 1000 } ?? 1_787_413_334_765
        let updated = stamp.map { $0.timeIntervalSince1970 * 1000 } ?? 1_787_413_874_925
        return """
            {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"/Users/x/src/app",\
            "startedAt":\(Int64(started)),"procStart":"Sat Aug 22 15:42:10 2026",\
            "version":"2.1.221","peerProtocol":1,"kind":"interactive",\
            "entrypoint":"cli","name":"app-5c","nameSource":"derived",\
            "status":"busy","updatedAt":\(Int64(updated)),"statusUpdatedAt":\(Int64(updated))}
            """
    }

    private func makeFakeClaudeHome() throws -> ClaudePaths {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-\(UUID().uuidString)")
        let paths = ClaudePaths(home: home)
        try FileManager.default.createDirectory(
            at: paths.sessionsDir, withIntermediateDirectories: true)
        return paths
    }

    @Test func projectsFieldsAndTranscriptURL() throws {
        let raw = try JSONValue(data: Data(registryJSON(pid: 1234).utf8))
        let session = RegistrySession(raw: raw)
        #expect(session.pid == 1234)
        #expect(session.sessionId == "sess-1")
        #expect(session.name == "app-5c")
        #expect(session.status == "busy")
        #expect(session.kind == "interactive")
        #expect(session.updatedAt != nil)

        let paths = ClaudePaths(home: URL(filePath: "/tmp/ch"))
        #expect(
            session.transcriptURL(paths: paths)?.path
                == "/tmp/ch/projects/-Users-x-src-app/sess-1.jsonl")
    }

    @Test func liveSessionsFiltersDeadPids() throws {
        let paths = try makeFakeClaudeHome()
        defer { try? FileManager.default.removeItem(at: paths.home) }

        let alivePid = ProcessInfo.processInfo.processIdentifier
        try Data(registryJSON(pid: alivePid, sessionId: "alive", stamp: Date()).utf8)
            .write(to: paths.sessionsDir.appendingPathComponent("\(alivePid).json"))
        // 99999 exceeds macOS's default pid range; treat as a crashed leftover.
        try Data(registryJSON(pid: 99999, sessionId: "stale").utf8)
            .write(to: paths.sessionsDir.appendingPathComponent("99999.json"))

        let live = SessionRegistry(paths: paths).liveSessions()
        #expect(live.map(\.sessionId) == ["alive"])
    }

    @Test func processLiveness() {
        #expect(SessionRegistry.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
        #expect(SessionRegistry.isProcessAlive(1))  // launchd: alive but not ours
        #expect(!SessionRegistry.isProcessAlive(0))
        #expect(!SessionRegistry.isProcessAlive(-5))
    }

    @Test func malformedRegistryFilesAreSkipped() throws {
        let paths = try makeFakeClaudeHome()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        try Data("not json at all".utf8)
            .write(to: paths.sessionsDir.appendingPathComponent("broken.json"))
        #expect(SessionRegistry(paths: paths).liveSessions().isEmpty)
    }

    @Test func pidTooLargeForInt32IsSkippedNotFatal() throws {
        let paths = try makeFakeClaudeHome()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        try Data(#"{"pid":3000000000,"sessionId":"s-huge","cwd":"/tmp"}"#.utf8)
            .write(to: paths.sessionsDir.appendingPathComponent("huge.json"))

        // The trapping conversion here aborted the whole app, and
        // liveSessions() reads pid for every file it finds.
        let sessions = SessionRegistry(paths: paths).liveSessions()
        #expect(sessions.isEmpty)
        #expect(RegistrySession(raw: try JSONValue(data: Data(#"{"pid":3000000000}"#.utf8))).pid == nil)
    }

    /// This process is alive and this process did not exist in 2020, so an
    /// entry claiming both is an entry whose pid has been reused. Before,
    /// the pid alone answered, and the dead session stayed live forever.
    @Test func aReusedPidDoesNotKeepADeadSessionLive() {
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        func entry(lastSeen: Date) -> RegistrySession {
            RegistrySession(raw: .object([
                "pid": .integer(Int64(mine)),
                "sessionId": .string("s1"),
                "cwd": .string("/tmp/x"),
                "startedAt": .number(lastSeen.timeIntervalSince1970 * 1000),
                "updatedAt": .number(lastSeen.timeIntervalSince1970 * 1000),
            ]))
        }
        #expect(!SessionRegistry.isLive(entry(lastSeen: Date(timeIntervalSince1970: 1_600_000_000))))
        #expect(SessionRegistry.isLive(entry(lastSeen: Date())))

    }

    /// `try?` here would swallow the requirement failure and leave the
    /// next line vacuously true, so the sysctl path could break in silence
    /// and this test would stay green.
    @Test func theKernelSaysWhenThisProcessBegan() throws {
        let mine = ProcessInfo.processInfo.processIdentifier
        let began = try #require(SessionRegistry.processStart(of: mine))
        #expect(began.timeIntervalSinceNow <= 0)
        #expect(began.timeIntervalSinceNow > -86_400 * 365)
        #expect(SessionRegistry.processStart(of: 0) == nil)
    }

    /// An entry whose recorded process start matches the kernel's is that
    /// process, whatever its heartbeat says — including a resumed session
    /// with no heartbeat at all, which the heartbeat rule alone would have
    /// called dead.
    @Test func aMatchingProcStartSettlesItWithoutAHeartbeat() throws {
        let mine = ProcessInfo.processInfo.processIdentifier
        let began = try #require(SessionRegistry.processStart(of: mine))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"

        let resumed = RegistrySession(raw: .object([
            "pid": .integer(Int64(mine)),
            "sessionId": .string("resumed"),
            "cwd": .string("/tmp/x"),
            // The original session, hours before this process existed.
            "startedAt": .number(began.addingTimeInterval(-7200).timeIntervalSince1970 * 1000),
            "procStart": .string(formatter.string(from: began)),
        ]))
        #expect(SessionRegistry.isLive(resumed))
    }

    @Test func procStartParsesTheShapeTheRegistryWrites() {
        // Single-digit days get ctime's second space.
        let padded = RegistrySession.parseProcStart("Sat Sep  5 03:03:30 2026")
        let plain = RegistrySession.parseProcStart("Fri Aug 29 00:54:01 2026")
        #expect(padded != nil)
        #expect(plain != nil)
        #expect(RegistrySession.parseProcStart("not a date") == nil)
    }

    /// An entry with no timestamps at all falls back to the pid, which is
    /// what it did before any of this.
    @Test func anEntryWithoutTimestampsStillTrustsThePid() {
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        let bare = RegistrySession(raw: .object([
            "pid": .integer(Int64(mine)), "sessionId": .string("s2"), "cwd": .string("/tmp/x"),
        ]))
        #expect(SessionRegistry.isLive(bare))
    }
}
