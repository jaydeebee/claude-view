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

        // Every transcript under projects/, not just the sessions' own:
        // agents live in <session>/subagents/, workflow agents a directory
        // deeper again, and on this machine that is 145 of the 155 files.
        // Drift that lands in an agent transcript first — the assembler's
        // duplicate-id bug did — is invisible to a listing that only reads
        // the top level.
        let transcripts = (fm.enumerator(
            at: paths.projectsDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter {
                // Journals are JSONL under the same tree but are not
                // transcripts; SessionAssembler reads them in its own mode.
                $0.pathExtension == "jsonl"
                    && $0.lastPathComponent != WorkflowRunIndex.journalFilename
            }
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

        #expect(lineCount > 0, "no transcripts found — is ~/.claude present?")
        #expect(transcripts.count > 0)
        // Not a failure: new kinds render as raw JSON. Surface them here so
        // format drift is visible in test output.
        if !unknownKinds.isEmpty {
            print("canary: unknown entry kinds observed: \(unknownKinds.sorted())")
        }
        print("canary: parsed \(lineCount) lines from \(transcripts.count) transcripts")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_VIEW_REAL_DATA"] == "1"))
    func assemblesEveryRealTranscript() throws {
        let paths = ClaudePaths()
        var totals = (transcripts: 0, rows: 0, orphans: 0, pending: 0)

        for project in SessionDiscovery(paths: paths).projects() {
            for transcript in project.transcripts {
                let dir = paths.subagentsDir(
                    projectSlug: project.slug, sessionId: transcript.sessionId)
                let subagents = SubagentIndex.load(dir: dir)
                // Agent transcripts too, not just the session's own: they
                // are where multi-block assistant entries cluster, and a
                // duplicate-id bug hid here for exactly that reason.
                let urls = [transcript.url] + subagentTranscripts(in: dir)

                for url in urls {
                    let data = try Data(contentsOf: url)
                    var entries: [TranscriptEntry] = []
                    for (i, line) in data.split(separator: UInt8(ascii: "\n")).enumerated()
                    where !line.isEmpty {
                        entries.append(try TranscriptEntry(line: Data(line), index: i))
                    }
                    let snapshot = SessionAssembler(subagents: subagents)
                        .assemble(entries: entries)

                    totals.transcripts += 1
                    totals.rows += snapshot.rows.count
                    #expect(
                        snapshot.rowIds.count == snapshot.rows.count,
                        "rowIds out of step with rows in \(url.lastPathComponent)")
                    var seen = Set<String>()
                    for id in snapshot.rowIds {
                        #expect(
                            seen.insert(id).inserted,
                            "duplicate row id \(id) in \(url.lastPathComponent)")
                    }
                    countInterestingRows(snapshot, into: &totals)
                }
            }
        }

        #expect(totals.transcripts > 0)
        print(
            "canary: assembled \(totals.transcripts) transcripts, "
                + "\(totals.rows) rows, \(totals.orphans) orphan results, "
                + "\(totals.pending) pending calls")
    }

    /// Recursive on purpose: workflow agents live a directory deeper, in
    /// subagents/workflows/wf_<id>/, and that is where every multi-block
    /// entry in this corpus turned out to be. A single-level listing
    /// walked 89 files and saw none of them.
    private func subagentTranscripts(in dir: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return walk.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent != "journal.jsonl" }
    }

    private func countInterestingRows(
        _ snapshot: SessionSnapshot,
        into totals: inout (transcripts: Int, rows: Int, orphans: Int, pending: Int)
    ) {
        for case .info(_, let label) in snapshot.rows
        where label == SessionRow.orphanToolResultLabel {
            totals.orphans += 1
        }
        for case .toolCall(let call) in snapshot.rows where call.isPending {
            totals.pending += 1
        }
    }
}
