import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct SessionRegistryTests {
    /// Fixture mirroring a real registry entry (v2.1.221), scrubbed.
    private func registryJSON(pid: Int32, sessionId: String = "sess-1") -> String {
        """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"/Users/x/src/app",\
        "startedAt":1787413334765,"procStart":"Sat Aug 22 15:42:10 2026",\
        "version":"2.1.221","peerProtocol":1,"kind":"interactive",\
        "entrypoint":"cli","name":"app-5c","nameSource":"derived",\
        "status":"busy","updatedAt":1787413874925,"statusUpdatedAt":1787413874925}
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
        try Data(registryJSON(pid: alivePid, sessionId: "alive").utf8)
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
}
