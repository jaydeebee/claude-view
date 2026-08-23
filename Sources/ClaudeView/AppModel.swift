import ClaudeViewCore
import Foundation
import Observation

/// Identifies one session in the UI, live or historical.
struct SessionRef: Hashable, Identifiable {
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

    private(set) var liveSessions: [RegistrySession] = []
    private(set) var projects: [ProjectListing] = []
    var selection: SessionRef?
    /// Sidebar filter: hide long-inactive agents when true.
    var agentFilterRunningOnly = false

    private let registry: SessionRegistry
    private let discovery: SessionDiscovery
    private var watcher: FSEventsWatcher?
    private var titleCache: [String: (modifiedAt: Date, title: String?)] = [:]

    init(paths: ClaudePaths = ClaudePaths()) {
        self.paths = paths
        self.registry = SessionRegistry(paths: paths)
        self.discovery = SessionDiscovery(paths: paths)
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

    func refresh() {
        liveSessions = registry.liveSessions()
        projects = discovery.projects()
    }

    // MARK: Sidebar derivations

    var liveRefs: [(session: RegistrySession, ref: SessionRef)] {
        liveSessions.compactMap { session in
            guard let sessionId = session.sessionId,
                let cwd = session.cwd
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

    private var liveSessionIds: Set<String> {
        Set(liveSessions.compactMap(\.sessionId))
    }

    /// History listing with live sessions removed (they sit in Live above).
    var historyProjects: [(project: ProjectListing, transcripts: [TranscriptFile])] {
        let live = liveSessionIds
        return projects.compactMap { project in
            let rest = project.transcripts.filter { !live.contains($0.sessionId) }
            guard !rest.isEmpty else { return nil }
            return (project, rest)
        }
    }

    /// "-Users-x-src-app" reads poorly; show it relative to $HOME when possible.
    nonisolated static func displayName(forSlug slug: String) -> String {
        let homeSlug = ClaudePaths.projectSlug(
            for: FileManager.default.homeDirectoryForCurrentUser.path)
        if slug.hasPrefix(homeSlug), slug.count > homeSlug.count + 1 {
            return String(slug.dropFirst(homeSlug.count + 1))
        }
        return slug
    }

    /// Sidebar title for a transcript, cached by modification time.
    func title(for transcript: TranscriptFile) -> String? {
        if let cached = titleCache[transcript.sessionId],
            cached.modifiedAt == transcript.modifiedAt
        {
            return cached.title
        }
        let title = TranscriptPeek.quickTitle(url: transcript.url)
        titleCache[transcript.sessionId] = (transcript.modifiedAt, title)
        return title
    }
}

/// An agent under a live session, surfaced in the sidebar tree. Background
/// agents never appear in the session registry, so running-ness is
/// inferred from transcript freshness.
struct ActiveSubagent: Identifiable {
    /// The usual indicators: spinner, orange for idle, dimmed when done.
    enum State {
        case processing  // transcript written in the last 30s
        case idle        // recent activity, not writing right now
        case inactive    // quiet for 10+ minutes
    }

    let ref: SessionRef
    let title: String
    let detail: String?
    let startedAt: Date?
    let lastActivity: Date
    /// 0 = spawned by the session; 1+ = spawned by another agent.
    let depth: Int

    var state: State {
        if lastActivity.timeIntervalSinceNow > -30 { return .processing }
        if lastActivity.timeIntervalSinceNow > -600 { return .idle }
        return .inactive
    }

    var id: String { ref.sessionId }
}

extension AppModel {
    /// The complete agent tree for one live session, children indented
    /// under the agent that spawned them. State (processing/idle/inactive)
    /// conveys age; the filter toggle prunes the inactive.
    func activeSubagents(for parent: SessionRef) -> [ActiveSubagent] {
        let dir = paths.subagentsDir(
            projectSlug: parent.projectSlug, sessionId: parent.sessionId)
        let index = SubagentIndex.load(dir: dir)
        let byParent = Dictionary(
            grouping: index.byAgentId.values, by: { $0.parentAgentId })

        var out: [ActiveSubagent] = []
        var visited = Set<String>()

        func append(parentAgentId: String?, depth: Int) {
            guard depth < 4 else { return }
            let group = (byParent[parentAgentId] ?? [])
                .compactMap { agent -> (SubagentRef, Date?, Date)? in
                    let values = try? agent.transcriptURL.resourceValues(
                        forKeys: [.creationDateKey, .contentModificationDateKey])
                    return (agent, values?.creationDate,
                            values?.contentModificationDate ?? .distantPast)
                }
                .sorted { ($0.1 ?? .distantPast) < ($1.1 ?? .distantPast) }
            for (agent, created, mtime) in group {
                guard visited.insert(agent.agentId).inserted else { continue }
                out.append(
                    ActiveSubagent(
                        ref: SessionRef(
                            projectSlug: parent.projectSlug,
                            sessionId: "agent-\(agent.agentId)",
                            url: agent.transcriptURL,
                            subagentsDir: dir),
                        title: agent.name ?? agent.agentType ?? "agent",
                        detail: agent.taskDescription,
                        startedAt: created,
                        lastActivity: mtime,
                        depth: depth))
                append(parentAgentId: agent.agentId, depth: depth + 1)
            }
        }
        append(parentAgentId: nil, depth: 0)
        return out
    }

    /// What the sidebar lists: everything, or only the not-yet-inactive.
    func sidebarAgents(for parent: SessionRef) -> [ActiveSubagent] {
        let agents = activeSubagents(for: parent)
        guard agentFilterRunningOnly else { return agents }
        return agents.filter { $0.state != .inactive }
    }

    /// Liveness/busyness for whatever the detail pane is showing. Sessions
    /// answer from the registry; agents answer from parent liveness plus
    /// their own transcript freshness.
    func status(for ref: SessionRef) -> (live: Bool, busy: Bool) {
        if let dir = ref.subagentsDir {
            let parentSessionId = dir.deletingLastPathComponent().lastPathComponent
            let live = liveSessions.contains { $0.sessionId == parentSessionId }
            let mtime = (try? ref.url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let busy = live && (mtime.map { $0.timeIntervalSinceNow > -20 } ?? false)
            return (live, busy)
        }
        let live = liveRefs.first { $0.ref == ref }
        return (live != nil, live?.session.status == "busy")
    }

    /// FSEvents drives refresh while files change; this slow heartbeat lets
    /// quiet-again subagents age out of the sidebar.
    func startHeartbeat() {
        Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self.refresh()
            }
        }
    }
}
