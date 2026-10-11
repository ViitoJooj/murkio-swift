import Foundation

/// Where the SDK keeps the session between runs of the app. The default is
/// the Keychain; pass another one to `Murkio.configure` to keep it elsewhere
/// (or `MurkioMemoryStorage` in tests).
public protocol MurkioStorage: Sendable {
    func read(_ key: String) -> String?
    func write(_ key: String, _ value: String)
    func delete(_ key: String)
}

/// Keeps everything in memory: the session ends with the process.
public final class MurkioMemoryStorage: MurkioStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func write(_ key: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    public func delete(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }

    /// The stored keys, for tests.
    public var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.keys)
    }
}
