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

    /// Every expectation here is what Node's `replace(/[^a-zA-Z0-9]/g, "-")`
    /// produces for the same string, which is the directory name Claude Code
    /// actually writes.
    @Test func projectSlugDashesEverythingOutsideASCIIAlphanumerics() {
        // Precomposed é is one UTF-16 unit: one dash, not a kept letter.
        #expect(
            ClaudePaths.projectSlug(for: "/Users/jos\u{e9}/proyecto")
                == "-Users-jos--proyecto")
        // Six kana, six dashes.
        #expect(
            ClaudePaths.projectSlug(for: "/Users/jdb/プロジェクト")
                == "-Users-jdb-------")
        // Decomposed é is two units: the `e` survives, the combining acute
        // becomes its own dash.
        #expect(
            ClaudePaths.projectSlug(for: "/Users/jdb/e\u{301}x")
                == "-Users-jdb-e-x")
        // Non-BMP: a surrogate pair is two units, so two dashes.
        #expect(ClaudePaths.projectSlug(for: "/a/🎉b") == "-a---b")
        // `isNumber` is true for both of these; the ASCII rule is not.
        #expect(
            ClaudePaths.projectSlug(for: "/Users/jdb/½-٣") == "-Users-jdb----")
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
