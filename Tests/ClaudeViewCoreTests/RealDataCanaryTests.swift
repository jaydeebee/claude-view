import Foundation
import Testing

@testable import ClaudeViewCore

/// Opt-in canary: parse every line of every transcript in the real ~/.claude.
///
/// The transcript format is internal to Claude Code and changes between
/// releases; run this after an update to find out what broke before the UI
/// does. Enabled with CLAUDE_VIEW_REAL_DATA=1 so normal test runs stay
/// hermetic.
@Suite struct RealDataCanaryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_VIEW_REAL_DATA"] == "1"))
    func parsesEveryRealTranscriptLine() throws {
        let paths = ClaudePaths()
        let fm = FileManager.default
        var lineCount = 0
        var unknownKinds = Set<String>()

        let projectDirs = (try? fm.contentsOfDirectory(
            at: paths.projectsDir, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let transcripts = ((try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            for url in transcripts {
                let data = try Data(contentsOf: url)
                var index = 0
                for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    let entry = try TranscriptEntry(line: Data(line), index: index)
                    if case .unknown(let type) = entry.kind {
                        unknownKinds.insert(type)
                    }
                    index += 1
                    lineCount += 1
                }
            }
        }

        #expect(lineCount > 0, "no transcripts found — is ~/.claude present?")
        // Not a failure: new kinds render as raw JSON. Surface them here so
        // format drift is visible in test output.
        if !unknownKinds.isEmpty {
            print("canary: unknown entry kinds observed: \(unknownKinds.sorted())")
        }
        print("canary: parsed \(lineCount) lines")
    }
}
