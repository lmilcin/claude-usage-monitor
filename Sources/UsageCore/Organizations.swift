import Foundation

/// A claude.ai organization as returned by `GET https://claude.ai/api/organizations`.
public struct Organization: Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case id = "uuid"
        case name
        case capabilities
    }

    public init(id: String, name: String, capabilities: [String]) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Organization"
        capabilities = (try? c.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
    }

    /// Whether this org is a claude.ai chat subscription (as opposed to an API-only console org).
    public var isChat: Bool { capabilities.contains("chat") }

    public static func parseList(_ data: Data) throws -> [Organization] {
        do {
            return try JSONDecoder().decode([Organization].self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(80), as: UTF8.self)
            throw UsageParseError.invalidJSON(snippet.isEmpty ? "empty body" : snippet)
        }
    }

    /// Picks the org to monitor: the explicitly preferred one if still present,
    /// otherwise the first chat-capable org, otherwise the first org.
    public static func choose(from orgs: [Organization], preferredID: String?) -> Organization? {
        if let preferredID, let match = orgs.first(where: { $0.id == preferredID }) {
            return match
        }
        return orgs.first(where: \.isChat) ?? orgs.first
    }
}
