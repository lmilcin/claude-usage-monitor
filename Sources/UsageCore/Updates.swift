import Foundation

/// A published release, as returned by GitHub's `GET /repos/{owner}/{repo}/releases/latest`.
public struct ReleaseInfo: Equatable, Sendable {
    /// The release tag without a leading "v", e.g. "0.2.0".
    public let version: String
    /// The release's page on github.com.
    public let pageURL: URL

    public init(version: String, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }
}

public enum UpdateChecker {
    /// Parses the JSON body of GitHub's "latest release" endpoint.
    /// Returns `nil` unless it has a tag and an https://github.com page URL
    /// (the URL is later opened in the browser, so it must not point elsewhere).
    public static func parseLatestRelease(_ data: Data) -> ReleaseInfo? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = root["tag_name"] as? String,
            let page = root["html_url"] as? String,
            let url = URL(string: page),
            url.scheme == "https", url.host == "github.com"
        else { return nil }
        let version = stripPrefix(tag)
        guard !version.isEmpty else { return nil }
        return ReleaseInfo(version: version, pageURL: url)
    }

    /// Whether `candidate` is a later version than `current`. Compares the numeric
    /// `major.minor.patch` core; a leading "v" and any "-suffix"/"+build" are ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Builds that don't come from a release tag are versioned "0.0.0-<something>"
    /// (see scripts/build-app.sh), so they can't be meaningfully compared with releases.
    public static func isDevelopmentBuild(_ version: String) -> Bool {
        components(version).allSatisfy { $0 == 0 }
    }

    private static func stripPrefix(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func components(_ version: String) -> [Int] {
        let core = stripPrefix(version).split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}
