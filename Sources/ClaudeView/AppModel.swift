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

/// A subagent currently doing work for a live session — surfaced in the
/// sidebar tree under its parent. Background forks never appear in the
/// session registry, so activity is inferred from transcript freshness.
struct ActiveSubagent: Identifiable {
    let ref: SessionRef
    let title: String
    let detail: String?

    var id: String { ref.sessionId }
}

extension AppModel {
    /// Top-level agents (not agents-of-agents) whose transcript was written
    /// to in the last couple of minutes.
    func activeSubagents(for parent: SessionRef) -> [ActiveSubagent] {
        let dir = paths.subagentsDir(
            projectSlug: parent.projectSlug, sessionId: parent.sessionId)
        let index = SubagentIndex.load(dir: dir)
        let cutoff = Date().addingTimeInterval(-120)

        return index.byAgentId.values
            .filter { $0.parentAgentId == nil }
            .compactMap { agent -> (SubagentRef, Date)? in
                let mtime = (try? agent.transcriptURL.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let mtime, mtime > cutoff else { return nil }
                return (agent, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .map { agent, _ in
                ActiveSubagent(
                    ref: SessionRef(
                        projectSlug: parent.projectSlug,
                        sessionId: "agent-\(agent.agentId)",
                        url: agent.transcriptURL,
                        subagentsDir: dir),
                    title: agent.name ?? agent.agentType ?? "agent",
                    detail: agent.taskDescription)
            }
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
