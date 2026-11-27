import Foundation

enum DataSource: String, CaseIterable {
    /// claude.ai web session cookie (`sessionKey`), same data as Settings → Usage.
    case claudeAI
    /// Claude Code's OAuth login, read from the macOS Keychain.
    case claudeCode

    var title: String {
        switch self {
        case .claudeAI: return "claude.ai Session Key"
        case .claudeCode: return "Claude Code Login (Keychain)"
        }
    }
}

enum IconMode: String, CaseIterable {
    case both, session, weekly

    var title: String {
        switch self {
        case .both: return "Session + Weekly"
        case .session: return "Session Only"
        case .weekly: return "Weekly Only"
        }
    }
}

/// User preferences, kept in UserDefaults. The session key is not here: it lives in the
/// Keychain and is read through `SessionKeyStore` (see AppDelegate).
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    static let refreshChoices = [1, 2, 5, 10, 15, 30]

    var dataSource: DataSource {
        get { defaults.string(forKey: "dataSource").flatMap(DataSource.init) ?? .claudeAI }
        set { defaults.set(newValue.rawValue, forKey: "dataSource") }
    }

    var refreshMinutes: Int {
        get {
            let value = defaults.integer(forKey: "refreshMinutes")
            return value > 0 ? value : 5
        }
        set { defaults.set(max(1, newValue), forKey: "refreshMinutes") }
    }

    var iconMode: IconMode {
        get { defaults.string(forKey: "iconMode").flatMap(IconMode.init) ?? .both }
        set { defaults.set(newValue.rawValue, forKey: "iconMode") }
    }

    var showPercentage: Bool {
        get { defaults.bool(forKey: "showPercentage") }
        set { defaults.set(newValue, forKey: "showPercentage") }
    }

    var organizationID: String? {
        get { defaults.string(forKey: "organizationID") }
        set { defaults.set(newValue, forKey: "organizationID") }
    }

    var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: "hasCompletedSetup") }
        set { defaults.set(newValue, forKey: "hasCompletedSetup") }
    }

    /// Ask GitHub once a day whether a newer release exists (on unless turned off).
    var autoUpdateCheck: Bool {
        get { defaults.object(forKey: "autoUpdateCheck") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoUpdateCheck") }
    }

    /// Accepts the raw cookie value, or a pasted `sessionKey=...` / full Cookie header.
    static func normalizeSessionKey(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "sessionKey=") {
            value = String(value[range.upperBound...])
            if let end = value.firstIndex(of: ";") { value = String(value[..<end]) }
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t"))
    }
}
