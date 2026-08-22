import ClaudeViewCore
import Foundation
import Observation

/// Live view-model for one transcript: accumulates entries from the tailer
/// and re-assembles the snapshot on every append.
///
/// Assembly is a pure fold over the entry list, cheap at real transcript
/// sizes; entries parse once and stick around.
@MainActor
@Observable
final class TranscriptModel {
    let ref: SessionRef
    let paths: ClaudePaths

    private(set) var snapshot = SessionSnapshot()
    var isLive = false

    private let tailer: JSONLTailer
    private var assembler = SessionAssembler()
    private var entries: [TranscriptEntry] = []
    private let subagentsDir: URL

    /// `subagentsDir` is derived from the ref for top-level sessions; a
    /// subagent's model passes its own directory so nested agents resolve.
    init(ref: SessionRef, paths: ClaudePaths, subagentsDir: URL? = nil) {
        self.ref = ref
        self.paths = paths
        self.tailer = JSONLTailer(url: ref.url)
        self.subagentsDir =
            subagentsDir
            ?? paths.subagentsDir(projectSlug: ref.projectSlug, sessionId: ref.sessionId)
    }

    /// Pull whatever the file has that we haven't seen. Cheap no-op when
    /// nothing changed, so callers can poll freely.
    func poll() {
        let lines = (try? tailer.poll()) ?? []
        if tailer.didResetOnLastPoll {
            entries.removeAll()
        }
        guard !lines.isEmpty else { return }

        for line in lines {
            // A malformed line (harness crash mid-write) shouldn't take the
            // session down with it.
            if let entry = try? TranscriptEntry(line: line, index: entries.count) {
                entries.append(entry)
            }
        }
        assembler.subagents = SubagentIndex.load(dir: subagentsDir)
        snapshot = assembler.assemble(entries: entries)
    }
}
