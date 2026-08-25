import ClaudeViewCore
import Foundation
import Observation

/// Identifies one session in the UI, live or historical.
struct SessionRef: Hashable, Identifiable, Sendable {
    let projectSlug: String
    let sessionId: String
    let url: URL
    /// For subagent transcripts opened directly: the parent session's
    /// subagents dir, so agents-spawned-by-agents still resolve.
    var subagentsDir: URL? = nil

    var id: String { sessionId }
}

/// Root observable state: what sessions exist, which one is selected.
///
/// FSEvents is only a wake-up call — every change handler re-reads the
/// registry and the project listing from disk, so missed or coalesced
/// events cost nothing but latency.
@MainActor
@Observable
final class AppModel {
    let paths: ClaudePaths

    /// The last completed scan. Everything the sidebar draws comes from
    /// here, so its body stays a pure read.
    private(set) var state = SidebarState()
    var selection: SessionRef?
    /// Sidebar filter: hide finished and long-inactive agents when true.
    var agentFilterRunningOnly = false

    private var watcher: FSEventsWatcher?
    @ObservationIgnored
    private let worker: SidebarWorker
    /// A scan in flight, and whether events arrived while it ran — a
    /// burst of FSEvents collapses into one follow-up rather than a queue
    /// of identical full scans.
    @ObservationIgnored
    private var scanning: Task<Void, Never>?
    @ObservationIgnored
    private var rescanWanted = false

    init(paths: ClaudePaths = ClaudePaths()) {
        self.paths = paths
        self.worker = SidebarWorker(paths: paths)
    }

    func start() {
        refresh()
        watcher = FSEventsWatcher(
            paths: [paths.projectsDir.path, paths.sessionsDir.path],
            latency: 0.3
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    /// Called when the window goes away. Deallocation alone can't be
    /// trusted to do this — SwiftUI may hold @State for a while — and a
    /// live watcher keeps firing refreshes for a window nobody can see.
    func stop() {
        watcher?.stop()
        watcher = nil
        scanning?.cancel()
        scanning = nil
    }

    /// Kicks off a scan unless one is already running, in which case one
    /// more follows it. The work itself happens on the worker; only the
    /// assignment lands here.
    func refresh() {
        guard scanning == nil else {
            rescanWanted = true
            return
        }
        scanning = Task { [weak self] in
            guard let self else { return }
            let scanned = await worker.scan()
            guard !Task.isCancelled else { return }
            self.state = scanned
            self.scanning = nil
            if self.rescanWanted {
                self.rescanWanted = false
                self.refresh()
            }
        }
    }

    // MARK: Sidebar derivations

    var liveRefs: [(session: RegistrySession, ref: SessionRef)] {
        // A session can briefly own two registry entries (a stale pid file
        // whose pid was recycled, then a resume). The registry lists
        // freshest first; keep that one — duplicate rows corrupt the List.
        var seen = Set<String>()
        return state.liveSessions.compactMap { session in
            guard let sessionId = session.sessionId,
                let cwd = session.cwd,
                seen.insert(sessionId).inserted
            else { return nil }
            let slug = ClaudePaths.projectSlug(for: cwd)
            return (
                session,
                SessionRef(
                    projectSlug: slug,
                    sessionId: sessionId,
                    url: paths.transcriptURL(projectSlug: slug, sessionId: sessionId))
            )
        }
    }

    /// History listing, live sessions already removed and trimmed by the
    /// worker (they sit in Live above).
    var historyProjects: [ProjectListing] { state.projects }

    /// Where a project's sessions ran, when a transcript could say.
    func path(forSlug slug: String) -> String? { state.projectPaths[slug] }

    /// "-Users-x-src-app" reads poorly; show it relative to $HOME when possible.
    nonisolated static func displayName(forSlug slug: String) -> String {
        let homeSlug = ClaudePaths.projectSlug(
            for: FileManager.default.homeDirectoryForCurrentUser.path)
        if slug.hasPrefix(homeSlug), slug.count > homeSlug.count + 1 {
            return String(slug.dropFirst(homeSlug.count + 1))
        }
        return slug
    }

    /// Sidebar title for a transcript, as of the last scan.
    func title(for transcript: TranscriptFile) -> String? {
        state.titles[transcript.url]
    }

    /// Context size for a sidebar row, as of the last scan.
    func contextUsage(for url: URL) -> ContextUsage? { state.usage[url] }
}

/// An agent under a live session, surfaced in the sidebar tree. Agents
/// never appear in the session registry, so done-ness comes from the
/// completion event in whoever spawned them; transcript freshness only
/// separates working from waiting while that event is outstanding.
struct ActiveSubagent: Identifiable, Sendable {
    /// The usual indicators: spinner, orange while unresolved, checkmark
    /// once the spawner has heard the end.
    enum State: Int {
        case completed = 0  // completion event seen, nothing since
        case inactive = 1   // no event, quiet for 10+ minutes
        case idle = 2       // no event, recent activity, not writing now
        case processing = 3  // transcript written in the last 30s
    }

    let ref: SessionRef
    let title: String
    let detail: String?
    let startedAt: Date?
    let lastActivity: Date
    /// When the spawner heard this agent stop; nil while unresolved.
    let completedAt: Date?
    var children: [ActiveSubagent] = []

    /// Transcript writes after the completion event mean the agent was
    /// revived (SendMessage); the old event no longer settles anything.
    private var isSettled: Bool {
        guard let completedAt else { return false }
        return lastActivity <= completedAt.addingTimeInterval(5)
    }

    var state: State {
        if isSettled { return .completed }
        if lastActivity.timeIntervalSinceNow > -30 { return .processing }
        if lastActivity.timeIntervalSinceNow > -600 { return .idle }
        return .inactive
    }

    /// What a collapsed parent shows: its own state or its busiest
    /// descendant's, whichever is more alive — code-review often idles
    /// while its finders work.
    var aggregateState: State {
        children.reduce(state) { max($0, $1.aggregateState) }
    }

    var id: String { ref.sessionId }
}

extension ActiveSubagent.State: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension AppModel {
    /// What the sidebar lists: everything, or — filtered — only agents that
    /// are still unresolved or shelter an unresolved descendant.
    func sidebarAgents(for parent: SessionRef) -> [ActiveSubagent] {
        let tree = state.agentTrees[parent.sessionId] ?? []
        guard agentFilterRunningOnly else { return tree }
        func prune(_ agents: [ActiveSubagent]) -> [ActiveSubagent] {
            agents.compactMap { agent in
                var kept = agent
                kept.children = prune(agent.children)
                return kept.state >= .idle || !kept.children.isEmpty ? kept : nil
            }
        }
        return prune(tree)
    }

    /// Liveness/busyness for whatever the detail pane is showing. Sessions
    /// answer from the registry; agents answer from parent liveness plus
    /// their own transcript freshness.
    func status(for ref: SessionRef) -> (live: Bool, busy: Bool) {
        if let dir = ref.subagentsDir {
            // Answered from the last scan rather than a fresh stat: this
            // runs in the detail pane's body.
            let components = dir.pathComponents
            let parentSessionId = components.lastIndex(of: "subagents")
                .flatMap { $0 > 0 ? components[$0 - 1] : nil }
            let live = state.liveSessions.contains { $0.sessionId == parentSessionId }
            let activity = state.agentActivity[ref.sessionId]
            let busy = live && (activity.map { $0.timeIntervalSinceNow > -20 } ?? false)
            return (live, busy)
        }
        let live = liveRefs.first { $0.ref == ref }
        return (live != nil, live?.session.status == "busy")
    }

}
