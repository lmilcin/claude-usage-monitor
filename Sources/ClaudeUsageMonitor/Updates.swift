import Foundation
import UsageCore

enum AppInfo {
    static let repository = "lmilcin/claude-usage-monitor"
    static let releasesURL = URL(string: "https://github.com/lmilcin/claude-usage-monitor/releases")!

    /// The bundle's version; "0.0.0-dev" when run outside an app bundle (`swift run`).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    }
}

enum UpdateError: LocalizedError {
    case http(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .http(let code): return "GitHub answered with HTTP \(code)."
        case .unexpectedResponse: return "GitHub's answer could not be understood."
        }
    }
}

/// Asks GitHub which release is the latest. Sends nothing but a generic User-Agent;
/// the app never downloads or installs anything itself.
struct UpdateService: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// The latest published release, or `nil` if the repository has none yet.
    func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("claude-usage-monitor", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.unexpectedResponse }
        switch http.statusCode {
        case 200:
            guard let release = UpdateChecker.parseLatestRelease(data) else {
                throw UpdateError.unexpectedResponse
            }
            return release
        case 404:
            return nil
        default:
            throw UpdateError.http(http.statusCode)
        }
    }
}
