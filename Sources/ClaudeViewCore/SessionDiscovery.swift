import Foundation

/// A transcript file found on disk — a session, live or finished.
public struct TranscriptFile: Sendable, Identifiable {
    public let sessionId: String
    public let url: URL
    public let modifiedAt: Date
    public let size: Int64

    public var id: String { sessionId }
}

/// One project directory under `~/.claude/projects`, with its transcripts
/// newest-first.
public struct ProjectListing: Sendable, Identifiable {
    public let slug: String
    public let url: URL
    public let transcripts: [TranscriptFile]

    public init(slug: String, url: URL, transcripts: [TranscriptFile]) {
        self.slug = slug
        self.url = url
        self.transcripts = transcripts
    }

    public var id: String { slug }
    public var lastActivity: Date { transcripts.first?.modifiedAt ?? .distantPast }
}

/// Enumerates what exists on disk. Liveness comes from the registry;
/// this is the browsable history of everything, keyed for joining.
public struct SessionDiscovery: Sendable {
    public let paths: ClaudePaths

    public init(paths: ClaudePaths) {
        self.paths = paths
    }

    /// All projects with at least one transcript, most recently active first.
    public func projects() -> [ProjectListing] {
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(
            at: paths.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        return projectDirs
            .compactMap { dir -> ProjectListing? in
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return nil }
                let transcripts = self.transcripts(in: dir)
                guard !transcripts.isEmpty else { return nil }
                return ProjectListing(
                    slug: dir.lastPathComponent, url: dir, transcripts: transcripts)
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func transcripts(in dir: URL) -> [TranscriptFile] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> TranscriptFile? in
                let values = try? url.resourceValues(forKeys: keys)
                return TranscriptFile(
                    sessionId: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
