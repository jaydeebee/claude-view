import Foundation

/// A dotted numeric version, tolerant of a leading "v" and blind to
/// prerelease suffixes — enough for comparing release tags.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        if let suffix = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<suffix])
        }
        let parts = s.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        components = parts.compactMap { $0 }
    }

    /// Missing components count as zero: 1.0 == 1.0.0.
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}

/// The newest published GitHub release, from /releases/latest.
public struct ReleaseInfo: Sendable {
    public let version: AppVersion
    public let tagName: String
    public let htmlURL: URL

    public init?(json: JSONValue) {
        guard json["draft"]?.boolValue != true,
            json["prerelease"]?.boolValue != true,
            let tag = json["tag_name"]?.stringValue,
            let version = AppVersion(tag),
            let urlString = json["html_url"]?.stringValue,
            let url = URL(string: urlString)
        else { return nil }
        self.version = version
        self.tagName = tag
        self.htmlURL = url
    }
}

public enum UpdateStatus: Sendable {
    /// No bundled version (swift run) — checks don't apply.
    case development
    case upToDate(AppVersion)
    case updateAvailable(ReleaseInfo)
    case unavailable(String)
}

public enum UpdateCheck {
    /// Compares the running version against the latest published GitHub
    /// release. The request carries version strings and nothing else.
    public static func run(
        currentVersion: String?, owner: String, repo: String
    ) async -> UpdateStatus {
        guard let currentVersion, let current = AppVersion(currentVersion) else {
            return .development
        }
        let url = URL(
            string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .unavailable(
                    status == 404
                        ? "No published releases found (the repository may be private)."
                        : "GitHub returned HTTP \(status).")
            }
            guard let release = ReleaseInfo(json: try JSONValue(data: data)) else {
                return .unavailable("The latest release could not be parsed.")
            }
            return release.version > current
                ? .updateAvailable(release)
                : .upToDate(current)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
