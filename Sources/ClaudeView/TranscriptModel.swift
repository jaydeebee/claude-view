import ClaudeViewCore
import Foundation
import Observation

/// Reads and folds a transcript away from the main actor. A 30MB session
/// takes seconds to parse; doing that inline froze the window on every
/// selection.
actor TranscriptLoader {
    private let tailer: JSONLTailer
    private let subagentsDir: URL
    private var assembler = SessionAssembler()
    private var entries: [TranscriptEntry] = []
    private var indexModifiedAt: Date?

    init(url: URL, subagentsDir: URL) {
        self.tailer = JSONLTailer(url: url)
        self.subagentsDir = subagentsDir
    }

    /// Whatever the file has that we haven't seen, folded into a fresh
    /// snapshot — or nil when nothing changed, so a quiet poll costs an
    /// lseek and the view is left alone.
    func poll() -> SessionSnapshot? {
        let lines = (try? tailer.poll()) ?? []
        if tailer.didResetOnLastPoll {
            entries.removeAll()
        } else if lines.isEmpty {
            return nil
        }

        for line in lines {
            // A malformed line (harness crash mid-write) shouldn't take the
            // session down with it.
            if let entry = try? TranscriptEntry(line: line, index: entries.count) {
                entries.append(entry)
            }
        }
        reloadSubagentsIfChanged()
        return assembler.assemble(entries: entries)
    }

    /// Every meta in the directory is re-read and re-parsed by a load; the
    /// directory's own timestamp says when that's worth doing.
    private func reloadSubagentsIfChanged() {
        let mtime = (try? subagentsDir.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard mtime != indexModifiedAt else { return }
        indexModifiedAt = mtime
        assembler.subagents = SubagentIndex.load(dir: subagentsDir)
    }
}

/// Live view-model for one transcript. Holds the snapshot the view draws
/// and nothing else — the reading and folding happen on the loader.
@MainActor
@Observable
final class TranscriptModel {
    let ref: SessionRef
    let paths: ClaudePaths

    private(set) var snapshot = SessionSnapshot()
    /// True once the first load has landed; until then the view has
    /// nothing to draw but a spinner.
    private(set) var hasLoaded = false
    var isLive = false

    @ObservationIgnored
    private let loader: TranscriptLoader

    /// `subagentsDir` is derived from the ref for top-level sessions; a
    /// subagent's model passes its own directory so nested agents resolve.
    init(ref: SessionRef, paths: ClaudePaths, subagentsDir: URL? = nil) {
        self.ref = ref
        self.paths = paths
        self.loader = TranscriptLoader(
            url: ref.url,
            subagentsDir: subagentsDir
                ?? paths.subagentsDir(
                    projectSlug: ref.projectSlug, sessionId: ref.sessionId))
    }

    /// Pull whatever the file has that we haven't seen. Cheap no-op when
    /// nothing changed, so callers can poll freely.
    func poll() async {
        if let snapshot = await loader.poll() {
            self.snapshot = snapshot
        }
        hasLoaded = true
    }
}
