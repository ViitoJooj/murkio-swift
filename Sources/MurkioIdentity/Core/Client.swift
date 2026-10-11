import Foundation

/// A 2FA challenge left by a social sign-in return, for the sign-in screen to continue.
struct PendingMfa: Sendable {
    let mfa: MfaChallenge
    let keepLogged: Bool
}

/// The client of one application: the session, the profile and the published
/// canvas. Apps get it from `Murkio.client`; the views use that one unless
/// they are given another.
public final class MurkioClient: @unchecked Sendable {
    /// The application's publishable key.
    public let publishableKey: String
    /// The https link a social sign-in comes back to, registered in the application's redirect URLs.
    public let oauthRedirectURL: String?
    /// The hash of the publishable key that names the storage records.
    public let keyHash: String
    /// The API client, for calls the SDK does not wrap.
    public let api: APIClient

    let sessions: SessionManager
    let configuredLocale: String?
    private let observed = Observed<MurkioSession?>(nil)
    private let oauthSignal = Observed<Int>(0)
    private let storage: MurkioStorage
    private let opener: @Sendable (String) -> Bool
    private let now: @Sendable () -> Int64
    private let caches = Caches()
    private let lock = NSLock()
    private var pendingMfa: PendingMfa?
    private var oauthError: MurkioError?

    init(
        publishableKey: String,
        apiURL: String? = nil,
        locale: String? = nil,
        oauthRedirectURL: String? = nil,
        storage: MurkioStorage,
        transport: MurkioTransport,
        opener: @escaping @Sendable (String) -> Bool = { _ in false },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        isForeground: @escaping @Sendable () -> Bool = { true }
    ) throws {
        guard publishableKey.hasPrefix("pk_") else {
            throw MurkioError(
                "invalid_key",
                message: "publishableKey must be a publishable key (pk_...). Never put a secret key (sk_) in an app."
            )
        }
        self.publishableKey = publishableKey
        self.oauthRedirectURL = oauthRedirectURL
        self.configuredLocale = locale
        self.storage = storage
        self.opener = opener
        self.now = now
        keyHash = fnv1a32(publishableKey)
        api = APIClient(publishableKey: publishableKey, apiURL: apiURL, transport: transport)
        sessions = SessionManager(api: api, storage: storage, keyHash: keyHash, observed: observed, now: now, isForeground: isForeground)
    }

    /// The signed-in session, or nil.
    public var currentSession: MurkioSession? { observed.value }

    public var isSignedIn: Bool { observed.value != nil }

    /// True when the app configured where a social sign-in comes back to.
    public var oauthEnabled: Bool { oauthRedirectURL != nil }

    /// The language the SDK speaks to the API (emails) and, unless a view says otherwise, on the built-in screens.
    public var locale: String { normalizeLocale(configuredLocale ?? deviceLocale()) }

    /// Calls `listener` whenever the session changes (sign-in, sign-out, refresh), on an arbitrary thread.
    @discardableResult
    public func observeSession(_ listener: @escaping @Sendable (MurkioSession?) -> Void) -> MurkioObservation {
        observed.observe(listener)
    }

    /// Calls `listener` when a social sign-in came back and left something for the sign-in screen.
    func observeOAuthReturn(_ listener: @escaping @Sendable () -> Void) -> MurkioObservation {
        oauthSignal.observe { _ in listener() }
    }

    /// Restores the session of the last run. Everything that needs the session waits for it.
    public func start() async {
        await caches.startOnce { await self.sessions.start() }
    }

    /// A valid access token for calling your own API, or nil. Refreshes it when needed.
    public func getToken() async throws -> String? {
        await start()
        return try await sessions.getToken()
    }

    /// The signed-in user's profile (email, roles, 2FA), cached for a minute per session.
    public func getUser() async throws -> MurkioUser? {
        guard let token = try await getToken(), let sessionId = currentSession?.sessionId else { return nil }
        let api = self.api
        return try await caches.user(sessionId: sessionId, now: now()) { try await api.me(accessToken: token) }
    }

    public func signOut() async {
        await start()
        await caches.forgetUser()
        await sessions.signOut()
    }

    /// The application id, its public config and the published canvas. It is
    /// fetched once, kept for a minute and then revalidated with its ETag, so
    /// most calls cost a 304 at most.
    public func bootstrap() async throws -> ClientBootstrap {
        let api = self.api
        return try await caches.bootstrap(now: now) { etag in try await api.bootstrap(etag: etag) }
    }

    /// Starts a social sign-in: the browser opens the provider, which comes
    /// back to `oauthRedirectURL`. Give that link to `handleRedirect`.
    public func startOAuth(provider: String, keepLogged: Bool) async throws {
        guard let redirect = oauthRedirectURL else {
            throw MurkioError("oauth.provider_disabled", message: "oauthRedirectURL is not configured")
        }
        let verifier = randomString(64)
        let state = randomString(32)
        let url = try await api.authorizeOAuth(provider: provider, redirectURL: redirect, state: state, codeChallenge: codeChallenge(verifier))
        guard url.hasPrefix("https://") else {
            throw MurkioError("oauth.server_error", message: "unexpected authorization url")
        }
        storage.write(oauthKey, JSONValue.object(["verifier": .string(verifier), "state": .string(state), "keepLogged": .bool(keepLogged)]).write())
        guard opener(url) else {
            storage.delete(oauthKey)
            throw MurkioError("oauth.server_error", message: "could not open the browser")
        }
    }

    /// Finishes a social sign-in with the link the app was opened with.
    /// Returns false when the link is not the answer to a sign-in this app
    /// started, so the app can handle it as any other link.
    @discardableResult
    public func handleRedirect(_ link: String) async -> Bool {
        let query = queryOf(link)
        guard let state = query["state"], !state.isEmpty else { return false }
        guard let attempt = storage.read(oauthKey).flatMap(JSONValue.parse), let verifier = attempt["verifier"]?.string,
              attempt["state"]?.string == state
        else { return false }
        storage.delete(oauthKey)
        let keepLogged = attempt["keepLogged"]?.bool == true

        do {
            guard query["error"] == nil, let code = query["code"] else {
                throw MurkioError("oauth.\(query["error"] ?? "server_error")")
            }
            switch try await api.exchangeOAuthCode(code: code, codeVerifier: verifier) {
            case .session(let tokens):
                await sessions.setSession(tokens, keepLogged: keepLogged)
            case .mfa(let mfa):
                withLock { pendingMfa = PendingMfa(mfa: mfa, keepLogged: keepLogged) }
                oauthSignal.set(oauthSignal.value + 1)
            }
        } catch {
            withLock { oauthError = MurkioError.from(error) }
            oauthSignal.set(oauthSignal.value + 1)
        }
        return true
    }

    /// Finishes a social sign-in with the URL the app was opened with.
    @discardableResult
    public func handleRedirect(_ url: URL) async -> Bool {
        await handleRedirect(url.absoluteString)
    }

    /// The 2FA challenge left by a social sign-in return, once.
    func takePendingMfa() -> PendingMfa? {
        withLock {
            let pending = pendingMfa
            pendingMfa = nil
            return pending
        }
    }

    /// The error of a social sign-in return, once.
    func takeOAuthError() -> MurkioError? {
        withLock {
            let error = oauthError
            oauthError = nil
            return error
        }
    }

    /// Opens a link outside the app (the browser, or the authenticator app for an `otpauth://` link).
    @discardableResult
    public func openURL(_ url: String) -> Bool {
        opener(url)
    }

    /// Called when the app comes to the foreground.
    func resumed() {
        let sessions = self.sessions
        Task { await sessions.refreshIfDue() }
    }

    private var oauthKey: String { "murkio.\(keyHash).oauth" }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The bootstrap and profile caches of a client, and the requests in flight for them.
private actor Caches {
    private static let ttlMs: Int64 = 60_000

    private var starting: Task<Void, Never>?
    private var bootstrapValue: (etag: String?, data: ClientBootstrap, at: Int64)?
    private var bootstrapping: Task<ClientBootstrap, Error>?
    private var userValue: (sessionId: String, at: Int64, task: Task<MurkioUser, Error>)?

    func startOnce(_ start: @escaping @Sendable () async -> Void) async {
        if starting == nil { starting = Task { await start() } }
        await starting?.value
    }

    func bootstrap(
        now: @escaping @Sendable () -> Int64,
        fetch: @escaping @Sendable (String?) async throws -> BootstrapResponse
    ) async throws -> ClientBootstrap {
        let cached = bootstrapValue
        if let cached, now() - cached.at < Caches.ttlMs { return cached.data }
        if let bootstrapping { return try await bootstrapping.value }

        let task = Task { () throws -> ClientBootstrap in
            do {
                let response = try await fetch(cached?.etag)
                guard let data = response.notModified ? (cached?.data ?? response.data) : response.data else {
                    throw MurkioError("unknown", message: "empty bootstrap")
                }
                self.store(etag: response.etag ?? cached?.etag, data: data, at: now())
                return data
            } catch {
                if let cached { return cached.data }
                throw error
            }
        }
        bootstrapping = task
        defer { bootstrapping = nil }
        return try await task.value
    }

    private func store(etag: String?, data: ClientBootstrap, at: Int64) {
        bootstrapValue = (etag, data, at)
    }

    func user(sessionId: String, now: Int64, fetch: @escaping @Sendable () async throws -> MurkioUser) async throws -> MurkioUser {
        if let cached = userValue, cached.sessionId == sessionId, now - cached.at <= Caches.ttlMs {
            return try await cached.task.value
        }
        let task = Task { try await fetch() }
        userValue = (sessionId, now, task)
        do {
            return try await task.value
        } catch {
            if let cached = userValue, cached.task == task { userValue = nil }
            throw error
        }
    }

    func forgetUser() {
        userValue = nil
    }
}

/// The query parameters of a link, percent-decoded. Written by hand so it
/// behaves the same on every platform.
func queryOf(_ link: String) -> [String: String] {
    guard let start = link.firstIndex(of: "?") else { return [:] }
    var query = link[link.index(after: start)...]
    if let fragment = query.firstIndex(of: "#") { query = query[..<fragment] }
    var result: [String: String] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]) : ""
        func decode(_ text: String) -> String {
            text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
        }
        result[decode(name)] = decode(value)
    }
    return result
}
