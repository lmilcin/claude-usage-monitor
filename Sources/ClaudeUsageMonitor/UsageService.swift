import Foundation
import UsageCore

enum UsageError: LocalizedError {
    case notConfigured(String)
    case unauthorized(String)
    case blockedByCloudflare
    case rateLimited
    case notFound
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): return message
        case .unauthorized(let message): return message
        case .blockedByCloudflare: return "Request was blocked by Cloudflare — try again later or set a fresh session key"
        case .rateLimited: return "Rate limited by the server — will retry on the next refresh"
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
    }

    func fetch(source: DataSource, sessionKey: String?, preferredOrgID: String?) async throws -> FetchResult {
        switch source {
        case .claudeAI:
            guard let sessionKey, !sessionKey.isEmpty else {
                throw UsageError.notConfigured("No claude.ai session key set — choose Settings → Set Session Key…")
            }
            return try await fetchClaudeAI(sessionKey: sessionKey, preferredOrgID: preferredOrgID)
        case .claudeCode:
            return try await fetchClaudeCode()
        }
    }

    // MARK: claude.ai (session cookie)

    private func fetchClaudeAI(sessionKey: String, preferredOrgID: String?, isRetry: Bool = false) async throws -> FetchResult {
        if organizations.isEmpty {
            let data = try await send(claudeAIRequest("https://claude.ai/api/organizations", sessionKey: sessionKey))
            organizations = try Organization.parseList(data)
        }
        guard let org = Organization.choose(from: organizations, preferredID: preferredOrgID) else {
            throw UsageError.notConfigured("This claude.ai account has no organizations")
        }

        do {
            let data = try await send(claudeAIRequest(
                "https://claude.ai/api/organizations/\(org.id)/usage", sessionKey: sessionKey))
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

    private func fetchClaudeCode(isRetry: Bool = false) async throws -> FetchResult {
        let credentials = try oauthCredentials(forceReload: isRetry)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-usage-monitor/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let data = try await send(request)
            return FetchResult(snapshot: try UsageParser.parse(data), organizations: [], organizationID: nil)
        } catch UsageError.unauthorized where !isRetry {
            // Claude Code may have refreshed the token since we cached it.
            cachedOAuth = nil
            return try await fetchClaudeCode(isRetry: true)
        } catch UsageError.unauthorized {
            throw UsageError.unauthorized("Claude Code token rejected — run `claude` in a terminal to refresh your login")
        }
    }

    private func oauthCredentials(forceReload: Bool) throws -> OAuthCredentials {
        if !forceReload, let cached = cachedOAuth, !cached.isExpired { return cached }
        guard let loaded = OAuthCredentials.load() else {
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

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.http(0, "no response") }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw UsageError.unauthorized("Session key invalid or expired — set a new one in Settings")
        case 403:
            if isCloudflareChallenge(http, data) { throw UsageError.blockedByCloudflare }
            throw UsageError.unauthorized("Access denied (403) — the session key may have expired")
        case 404:
            throw UsageError.notFound
        case 429:
            throw UsageError.rateLimited
        default:
            if isCloudflareChallenge(http, data) { throw UsageError.blockedByCloudflare }
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

    static func load() -> OAuthCredentials? {
        if let data = Keychain.read(service: "Claude Code-credentials"), let creds = parse(data) {
            return creds
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let creds = parse(data) {
            return creds
        }
        return nil
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
