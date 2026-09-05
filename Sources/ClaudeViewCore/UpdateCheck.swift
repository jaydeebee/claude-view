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
        var parsed: [Int] = []
        for part in s.split(separator: ".") {
            guard let component = Int(part) else { return nil }
            parsed.append(component)
        }
        guard !parsed.isEmpty else { return nil }
        components = parsed
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
            let url = URL(string: urlString),
            // This is handed to NSWorkspace, which will open whatever
            // scheme it is given — file:, and worse. The field comes off
            // the network, so it is checked before it is trusted, however
            // unlikely GitHub is to be the one lying.
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else { return nil }
        self.version = version
        self.tagName = tag
        self.htmlURL = url
    }
}

public enum UpdateStatus: Sendable {
    /// No bundled version (swift run) — checks don't apply.
    case development
    case upToDate(current: AppVersion, latest: AppVersion)
    case updateAvailable(ReleaseInfo)
    case unavailable(String)
}

public enum UpdateCheck {
    /// A short-fuse, cache-free session: the check is fire-and-forget, so
    /// don't ride URLSession's default 60-second timeout or write GitHub
    /// responses into the shared on-disk cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// Compares the running version against the latest published GitHub
    /// release. The request carries version strings and nothing else.
    public static func run(
        currentVersion: String?, owner: String, repo: String
    ) async -> UpdateStatus {
        guard let currentVersion else { return .development }
        guard let current = AppVersion(currentVersion) else {
            return .unavailable(
                "The bundled version \"\(currentVersion)\" is not a dotted "
                    + "numeric version, so it can't be compared with releases.")
        }
        guard
            let url = URL(
                string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
        else {
            return .unavailable("Not a valid GitHub repository: \(owner)/\(repo).")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .unavailable(
                    status == 404
                        ? "No published releases found (the repository may be private)."
                        : "GitHub returned HTTP \(status).")
            }
            guard let json = try? JSONValue(data: data),
                let release = ReleaseInfo(json: json)
            else {
                return .unavailable("The latest release could not be parsed.")
            }
            return release.version > current
                ? .updateAvailable(release)
                : .upToDate(current: current, latest: release.version)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
