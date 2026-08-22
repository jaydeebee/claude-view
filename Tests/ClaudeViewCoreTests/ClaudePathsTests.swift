import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct ClaudePathsTests {
    @Test func projectSlugReplacesNonAlphanumerics() {
        #expect(
            ClaudePaths.projectSlug(for: "/Users/jdb/src/claude-view")
                == "-Users-jdb-src-claude-view")
        #expect(
            ClaudePaths.projectSlug(for: "/Users/jdb/src/thermo.node_v2")
                == "-Users-jdb-src-thermo-node-v2")
    }

    @Test func pathsHangTogether() {
        let paths = ClaudePaths(home: URL(filePath: "/tmp/fake-claude"))
        #expect(paths.projectsDir.path == "/tmp/fake-claude/projects")
        #expect(paths.sessionsDir.path == "/tmp/fake-claude/sessions")
        #expect(
            paths.transcriptURL(projectSlug: "-a-b", sessionId: "1234").path
                == "/tmp/fake-claude/projects/-a-b/1234.jsonl")
        #expect(
            paths.subagentsDir(projectSlug: "-a-b", sessionId: "1234").path
                == "/tmp/fake-claude/projects/-a-b/1234/subagents")
    }
}
