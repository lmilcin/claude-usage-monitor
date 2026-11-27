import Foundation

/// What a secret store answered when asked for its value.
public enum SecretReadResult: Equatable, Sendable {
    case found(String)
    case notFound
    /// The user refused access (e.g. clicked "Deny" on the Keychain prompt).
    case denied
    /// Any other failure, with the store's status code.
    case failed(Int32)
}

public struct SecretStoreError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Where the secret is actually kept (the login Keychain in the app, a fake in tests).
/// Calls may block for as long as a system prompt is on screen.
public protocol SecretBackend: Sendable {
    func read() -> SecretReadResult
    /// Stores `value`, or deletes the stored value when it is `nil`.
    func write(_ value: String?) throws
}

/// Keeps a secret in memory so the backing store is read at most once per launch.
///
/// On macOS, every Keychain read by an app the item doesn't trust shows a password prompt and
/// blocks until it is answered. An ad-hoc signed app counts as a new app after every update, so
/// reading on every refresh or menu rebuild turns into a stream of prompts. Being an actor, this
/// also keeps those blocking calls off the main thread.
public actor CachedSecret {
    public enum Status: Equatable, Sendable {
        /// Not read yet, or the last read failed in a way that is worth retrying.
        case unknown
        case missing
        case present
        /// The user refused access. Not asked again until `reset()` or `save(_:)`.
        case denied
        /// The last read failed; the next `load()` tries again.
        case failed(Int32)
    }

    private let backend: SecretBackend
    private var value: String?
    public private(set) var status: Status = .unknown

    public init(backend: SecretBackend) {
        self.backend = backend
    }

    /// The secret, reading the backend only if it hasn't been read successfully yet.
    public func load() -> (status: Status, value: String?) {
        switch status {
        case .missing, .present, .denied:
            return (status, value)
        case .unknown, .failed:
            break
        }
        switch backend.read() {
        case .found(let secret) where !secret.isEmpty:
            value = secret
            status = .present
        case .found, .notFound:
            value = nil
            status = .missing
        case .denied:
            value = nil
            status = .denied
        case .failed(let code):
            value = nil
            status = .failed(code)
        }
        return (status, value)
    }

    /// Stores a new secret (or removes it when `nil` or empty). The in-memory value is updated
    /// even if the backend fails, so the app keeps working until it quits; the error says why
    /// the change won't survive a restart.
    public func save(_ newValue: String?) throws {
        let secret = (newValue?.isEmpty ?? true) ? nil : newValue
        value = secret
        status = secret == nil ? .missing : .present
        try backend.write(secret)
    }

    /// Forgets the cached state so the next `load()` asks the backend again.
    public func reset() {
        value = nil
        status = .unknown
    }
}
