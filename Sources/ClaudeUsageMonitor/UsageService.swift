import Foundation
import UsageCore

enum UsageError: LocalizedError {
    case notConfigured(String)
    case unauthorized(String)
    case blockedByCloudflare(DataSource)
    /// HTTP 429, with the server's `Retry-After` in seconds if it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    case notFound
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): return message
        case .unauthorized(let message): return message
        case .blockedByCloudflare(let source):
            return "Request was blocked by Cloudflare — try again later"
                + (source == .claudeAI ? " or set a fresh session key" : "")
        case .rateLimited: return "Rate limited by the server — backing off"
        case .notFound: return "Organization not found"
        case .http(let code, let body): return "HTTP \(code)" + (body.isEmpty ? "" : ": \(body)")
        }
    }

    /// Errors the user has to act on (as opposed to transient ones).
    var needsUserAction: Bool {
        switch self {
        case .notConfigured, .unauthorized: return true
        default: return false
        }
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// Whether the server is telling us to slow down, so automatic refreshes should back off.
    var isThrottling: Bool {
        switch self {
        case .rateLimited, .blockedByCloudflare: return true
        case .http(let code, _): return code >= 500
        default: return false
        }
    }

    var retryAfter: TimeInterval? {
        if case .rateLimited(let retryAfter) = self { return retryAfter }
        return nil
    }
}

struct FetchResult: Sendable {
    let snapshot: UsageSnapshot
    /// Organizations visible to the session key (claude.ai source only).
    let organizations: [Organization]
    let organizationID: String?
}

/// Talks to the usage endpoints. An actor so that network and Keychain access
/// (which may show a system prompt and block) stay off the main thread.
actor UsageService {
    private let session: URLSession
    private var organizations: [Organization] = []
    private var cachedOAuth: OAuthCredentials?
    /// Set when the user refused Keychain access to Claude Code's login, so the app doesn't
    /// ask again on every refresh. Cleared by `reset()` (switching data source) or relaunching.
    private var oauthAccessDenied = false
    /// The credential (session key or Claude Code access token) the server last rejected, and
    /// the error it caused. Automatic refreshes don't send that credential again; they fail
    /// locally with the same error until the credential changes. "Refresh Now" still sends it.
    private var rejection: (credential: String, error: UsageError)?

    // A browser-like UA; claude.ai sits behind Cloudflare, which is wary of unknown clients.
    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Forget cached orgs/tokens (call after the session key or source changes).
    func reset() {
        organizations = []
        cachedOAuth = nil
        oauthAccessDenied = false
        rejection = nil
    }

    /// - Parameter userInitiated: true for "Refresh Now" and settings changes. Those also retry
    ///   a credential the server has rejected; automatic refreshes don't.
    func fetch(
        source: DataSource, sessionKey: String?, preferredOrgID: String?, userInitiated: Bool
    ) async throws -> FetchResult {
        switch source {
        case .claudeAI:
            guard let sessionKey, !sessionKey.isEmpty else {
                throw UsageError.notConfigured("No claude.ai session key set — choose Settings → Set Session Key…")
            }
            try checkNotRejected(sessionKey, userInitiated: userInitiated)
            do {
                let result = try await fetchClaudeAI(sessionKey: sessionKey, preferredOrgID: preferredOrgID)
                rejection = nil
                return result
            } catch let error as UsageError where error.isUnauthorized {
                rejection = (sessionKey, error)
                throw error
            }
        case .claudeCode:
            let result = try await fetchClaudeCode(userInitiated: userInitiated)
            rejection = nil
            return result
        }
    }

    private func checkNotRejected(_ credential: String, userInitiated: Bool) throws {
        if !userInitiated, let rejection, rejection.credential == credential {
            throw rejection.error
        }
    }

    // MARK: claude.ai (session cookie)

    private func fetchClaudeAI(sessionKey: String, preferredOrgID: String?, isRetry: Bool = false) async throws -> FetchResult {
        if organizations.isEmpty {
            let data = try await send(
                claudeAIRequest("https://claude.ai/api/organizations", sessionKey: sessionKey), source: .claudeAI)
            organizations = try Organization.parseList(data)
        }
        guard let org = Organization.choose(from: organizations, preferredID: preferredOrgID) else {
            throw UsageError.notConfigured("This claude.ai account has no organizations")
        }

        do {
            let data = try await send(claudeAIRequest(
                "https://claude.ai/api/organizations/\(org.id)/usage", sessionKey: sessionKey), source: .claudeAI)
            let snapshot = try UsageParser.parse(data)
            return FetchResult(snapshot: snapshot, organizations: organizations, organizationID: org.id)
        } catch UsageError.notFound where !isRetry {
            // Org list may be stale (e.g. left a team); reload it once.
            organizations = []
            return try await fetchClaudeAI(sessionKey: sessionKey, preferredOrgID: nil, isRetry: true)
        }
    }

    private func claudeAIRequest(_ url: String, sessionKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        return request
    }

    // MARK: Claude Code (OAuth token from Keychain)

    private func fetchClaudeCode(userInitiated: Bool, isRetry: Bool = false) async throws -> FetchResult {
        // While a token is rejected, re-read the Keychain each time: running `claude` replaces it.
        let credentials = try oauthCredentials(forceReload: isRetry || rejection != nil)
        // The retry after a 401 only makes sense if Claude Code has stored a different token.
        try checkNotRejected(credentials.accessToken, userInitiated: userInitiated && !isRetry)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-usage-monitor/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let data = try await send(request, source: .claudeCode)
            return FetchResult(snapshot: try UsageParser.parse(data), organizations: [], organizationID: nil)
        } catch UsageError.unauthorized {
            let error = UsageError.unauthorized(
                "Claude Code token rejected — run `claude` in a terminal to refresh your login")
            rejection = (credentials.accessToken, error)
            if isRetry { throw error }
            // Claude Code may have refreshed the token since we cached it.
            cachedOAuth = nil
            return try await fetchClaudeCode(userInitiated: userInitiated, isRetry: true)
        } catch UsageError.notFound {
            // `.notFound` reads "Organization not found", which only makes sense for claude.ai.
            throw UsageError.http(404, "usage endpoint not found — check for an app update")
        }
    }

    private func oauthCredentials(forceReload: Bool) throws -> OAuthCredentials {
        if !forceReload, let cached = cachedOAuth, !cached.isExpired { return cached }
        if oauthAccessDenied { throw OAuthCredentials.accessDeniedError }
        let loaded: OAuthCredentials
        switch OAuthCredentials.load() {
        case .found(let credentials):
            loaded = credentials
        case .denied:
            oauthAccessDenied = true
            throw OAuthCredentials.accessDeniedError
        case .notFound:
            throw UsageError.notConfigured(
                "Claude Code login not found in Keychain — run `claude` and log in, or use a claude.ai session key")
        }
        cachedOAuth = loaded
        if loaded.isExpired {
            // We deliberately don't refresh it ourselves: refresh tokens rotate, and doing so
            // would silently log Claude Code out.
            throw UsageError.unauthorized(
                "Claude Code token expired — run `claude` in a terminal once to refresh it")
        }
        return loaded
    }

    // MARK: HTTP

    private func send(_ request: URLRequest, source: DataSource) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.http(0, "no response") }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw UsageError.unauthorized("Session key invalid or expired — set a new one in Settings")
        case 403:
            if isCloudflareChallenge(http, data) { throw UsageError.blockedByCloudflare(source) }
            throw UsageError.unauthorized("Access denied (403) — the session key may have expired")
        case 404:
            throw UsageError.notFound
        case 429:
            throw UsageError.rateLimited(
                retryAfter: RetryAfter.parse(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            if isCloudflareChallenge(http, data) { throw UsageError.blockedByCloudflare(source) }
            let body = String(decoding: data.prefix(120), as: UTF8.self)
            throw UsageError.http(http.statusCode, body)
        }
    }

    private func isCloudflareChallenge(_ response: HTTPURLResponse, _ data: Data) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated") != nil { return true }
        let body = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return body.contains("<html") && (body.contains("cloudflare") || body.contains("just a moment"))
    }
}

/// Claude Code stores its login as JSON in the Keychain item "Claude Code-credentials"
/// (or in ~/.claude/.credentials.json on some setups):
/// `{"claudeAiOauth": {"accessToken": "...", "refreshToken": "...", "expiresAt": 1730000000000, ...}}`
struct OAuthCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 30
    }

    enum LoadResult {
        case found(OAuthCredentials)
        case denied
        case notFound
    }

    static let accessDeniedError = UsageError.notConfigured(
        "Keychain access to the Claude Code login was denied — choose the data source again, "
            + "or relaunch the app, to be asked again")

    /// Reads the Keychain item, then the file. Blocks while a Keychain prompt is on screen.
    static func load() -> LoadResult {
        let keychain = Keychain.read(service: "Claude Code-credentials")
        if case .found(let json) = keychain, let creds = parse(Data(json.utf8)) {
            return .found(creds)
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let creds = parse(data) {
            return .found(creds)
        }
        return keychain == .denied ? .denied : .notFound
    }

    static func parse(_ data: Data) -> OAuthCredentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        return OAuthCredentials(
            accessToken: token,
            expiresAt: expiresMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
