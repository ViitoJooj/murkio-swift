import Foundation

/// The signed-in session: the tokens and when the access token expires.
public struct MurkioSession: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    /// Milliseconds since the epoch.
    public let expiresAt: Int64
    public let sessionId: String
    /// "Keep me signed in" was off: the session does not survive the app.
    public let ephemeral: Bool

    public init(accessToken: String, refreshToken: String, expiresAt: Int64, sessionId: String, ephemeral: Bool) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.sessionId = sessionId
        self.ephemeral = ephemeral
    }

    /// The claims of the access token, read without checking its signature.
    public var claims: AccessClaims? { decodeClaims(accessToken) }

    public var userId: String? { claims?.subject }

    public var roles: [String] { claims?.roles ?? [] }

    func toJSON() -> String {
        JSONValue.object([
            "accessToken": .string(accessToken),
            "refreshToken": .string(refreshToken),
            "expiresAt": .number(Double(expiresAt)),
            "sessionId": .string(sessionId),
            "ephemeral": .bool(ephemeral),
        ]).write()
    }

    init?(json text: String?) {
        guard let text, let json = JSONValue.parse(text),
            let access = json["accessToken"]?.string, let refresh = json["refreshToken"]?.string,
            let expires = json["expiresAt"]?.number, let session = json["sessionId"]?.string
        else { return nil }
        self.init(accessToken: access, refreshToken: refresh, expiresAt: Int64(expires), sessionId: session, ephemeral: json["ephemeral"]?.bool == true)
    }
}

/// Something the app is observing; `cancel()` stops it.
public final class MurkioObservation: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel()
    }
}

/// A value with listeners, readable from any thread without waiting.
final class Observed<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    private var listeners: [Int: @Sendable (Value) -> Void] = [:]
    private var nextId = 0

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        let current = Array(listeners.values)
        lock.unlock()
        for listener in current { listener(value) }
    }

    func observe(_ listener: @escaping @Sendable (Value) -> Void) -> MurkioObservation {
        lock.lock()
        let id = nextId
        nextId += 1
        listeners[id] = listener
        lock.unlock()
        return MurkioObservation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.listeners[id] = nil
            self.lock.unlock()
        }
    }
}

/// Sessions stored by this process. An ephemeral record that is not here was
/// left by a previous run of the app.
private final class AliveSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}

/// SessionManager keeps the user's tokens.
///
/// - One record in the storage, named after the publishable key.
/// - Refreshes run one at a time: the refresh token rotates on every use and
///   the API revokes the whole session when a used one shows up again
///   (rsb-03), so concurrent callers share one request. That request is its
///   own task: a caller that is cancelled does not cancel it, or the rotated
///   token would be lost with the answer.
/// - "Keep me signed in" off marks the record ephemeral: the next start of
///   the app finds it, logs it out and deletes it.
/// - A network error keeps the session; only the API saying the session is
///   over signs the user out.
actor SessionManager {
    /// Refresh this long before the access token expires.
    static let refreshMarginMs: Int64 = 90_000
    private static let minimumWaitMs: Int64 = 10_000
    /// A refresh answered with one of these means the session is over.
    private static let endedCodes: Set<String> = ["rsb-02", "rsb-03", "rsb-05"]
    private static let alive = AliveSessions()

    private let api: APIClient
    private let storage: MurkioStorage
    private let keyHash: String
    private let now: @Sendable () -> Int64
    private let isForeground: @Sendable () -> Bool
    private let observed: Observed<MurkioSession?>
    private var inflight: Task<MurkioSession?, Error>?
    private var timer: Task<Void, Never>?

    init(
        api: APIClient, storage: MurkioStorage, keyHash: String, observed: Observed<MurkioSession?>,
        now: @escaping @Sendable () -> Int64, isForeground: @escaping @Sendable () -> Bool
    ) {
        self.api = api
        self.storage = storage
        self.keyHash = keyHash
        self.observed = observed
        self.now = now
        self.isForeground = isForeground
    }

    private var key: String { "murkio.\(keyHash).session" }

    private var current: MurkioSession? { observed.value }

    /// Restores the session of a previous run and keeps it fresh.
    func start() async {
        let stored = MurkioSession(json: storage.read(key))
        if let stored, stored.ephemeral, !SessionManager.alive.contains("\(keyHash):\(stored.sessionId)") {
            let api = self.api
            Task { try? await api.logout(stored.refreshToken) }
            storage.delete(key)
            set(nil)
            return
        }
        set(stored)
        if isForeground() { await refreshIfDue() }
    }

    @discardableResult
    func setSession(_ tokens: TokenPair, keepLogged: Bool) -> MurkioSession {
        let session = MurkioSession(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: now() + Int64(tokens.expiresIn) * 1000,
            sessionId: tokens.sessionId,
            ephemeral: !keepLogged
        )
        SessionManager.alive.insert("\(keyHash):\(session.sessionId)")
        set(session)
        storage.write(key, session.toJSON())
        return session
    }

    /// A valid access token, refreshed first when it expires within
    /// `minValidityMs`. Nil when nobody is signed in or the session is over.
    func getToken(minValidityMs: Int64 = 30_000) async throws -> String? {
        guard let session = current else { return nil }
        if session.expiresAt - now() > minValidityMs { return session.accessToken }
        return try await refresh()?.accessToken
    }

    /// Renews the tokens, once for every caller that asks at the same time.
    /// Network errors keep the session and throw.
    func refresh() async throws -> MurkioSession? {
        if let inflight { return try await inflight.value }
        let task = Task { try await self.performRefresh() }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> MurkioSession? {
        guard var before = current else { return nil }

        // Another process of the app (an extension) may already have used the refresh token.
        if let stored = MurkioSession(json: storage.read(key)), stored.sessionId == before.sessionId,
            stored.refreshToken != before.refreshToken
        {
            before = stored
            set(stored)
        }
        if before.expiresAt - now() > SessionManager.refreshMarginMs { return before }

        let pair: TokenPair
        do {
            pair = try await api.refresh(before.refreshToken)
        } catch let error as MurkioError where SessionManager.endedCodes.contains(error.code) {
            clear()
            return nil
        }

        // The user signed out while the request was on its way: the new tokens must not bring the session back.
        guard let latest = current else {
            let api = self.api
            Task { try? await api.logout(pair.refreshToken) }
            return nil
        }
        return setSession(pair, keepLogged: !latest.ephemeral)
    }

    /// Renews the tokens when they are about to expire; errors are left for
    /// the next `getToken` to report.
    func refreshIfDue() async {
        guard let session = current, session.expiresAt - now() <= SessionManager.refreshMarginMs else { return }
        _ = try? await refresh()
    }

    func signOut() async {
        let session = current
        clear()
        if let session {
            // The record is gone either way; the API expires the session itself.
            try? await api.logout(session.refreshToken)
        }
    }

    func clear() {
        set(nil)
        storage.delete(key)
    }

    func close() {
        timer?.cancel()
        timer = nil
    }

    private func set(_ session: MurkioSession?) {
        observed.set(session)
        timer?.cancel()
        timer = nil
        guard let session else { return }
        // Never sooner than a few seconds: with a token that lives less than the
        // margin, "refresh when due" would otherwise call the API in a loop.
        let wait = max(session.expiresAt - SessionManager.refreshMarginMs - now(), SessionManager.minimumWaitMs)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() async {
        if isForeground() { await refreshIfDue() }
    }
}
