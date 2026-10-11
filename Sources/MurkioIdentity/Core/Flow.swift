import Foundation

/// Where the user is in the sign-in.
public enum FlowStep: Equatable, Sendable {
    /// The sign-in (or sign-up) screen: the canvas, or the app's own form.
    case signIn
    /// The code sent to the email. `needsPassword` is true when the SDK no longer has the password the confirmation needs.
    case verifyEmail(email: String, needsPassword: Bool)
    /// The code of the authenticator app (or a recovery code).
    case mfa(token: String)
    /// The application requires 2FA: the user adds `secret` to an authenticator.
    case mfaEnroll(token: String, secret: String, otpauthUri: String)
    /// The recovery codes to save. The session starts after the user confirms.
    case recoveryCodes([String])
    /// "Forgot password": asks for the email.
    case forgot
    /// The code sent to `email` and the new password.
    case reset(email: String)
    /// The session is stored: the user is signed in.
    case done

    /// The name of the step, the same in every Murkio SDK.
    public var name: String {
        switch self {
        case .signIn: return "sign_in"
        case .verifyEmail: return "verify_email"
        case .mfa: return "mfa"
        case .mfaEnroll: return "mfa_enroll"
        case .recoveryCodes: return "recovery_codes"
        case .forgot: return "forgot"
        case .reset: return "reset"
        case .done: return "done"
        }
    }
}

/// What a sign-in screen draws: the step, whether a request is running, the
/// error of the last action and a notice (the key of a built-in string, see
/// `murkioString`).
public struct FlowState: Equatable, Sendable {
    public var step: FlowStep = .signIn
    public var busy = false
    public var error: MurkioError?
    public var notice: String?

    public init(step: FlowStep = .signIn, busy: Bool = false, error: MurkioError? = nil, notice: String? = nil) {
        self.step = step
        self.busy = busy
        self.error = error
        self.notice = notice
    }

    /// True for the steps a built-in screen draws (everything between the sign-in screen and the session).
    public var inStep: Bool { step != .signIn && step != .done }
}

/// What the user typed on the sign-in screen.
public struct MurkioCredentials: Equatable, Sendable {
    public let email: String
    public let password: String
    public let keepLogged: Bool

    public init(email: String, password: String, keepLogged: Bool = false) {
        self.email = email
        self.password = password
        self.keepLogged = keepLogged
    }
}

private func normalizeEmail(_ email: String) -> String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// FlowController walks a user through signing in: the password login, the
/// signup and its email code, the 2FA challenge (and the forced enrollment),
/// the password reset and the social sign-in. The canvas and the standalone
/// views draw its `state`; it holds the password only in memory, between the
/// signup and the email code, because the confirmation needs it.
@MainActor
public final class FlowController {
    public let client: MurkioClient
    public private(set) var state = FlowState() {
        didSet {
            guard state != oldValue else { return }
            for listener in listeners.values { listener(state) }
        }
    }

    private var listeners: [Int: (FlowState) -> Void] = [:]
    private var nextListener = 0
    private var email = ""
    private var password = ""
    private var keepLogged = false
    private var pendingSession: TokenPair?
    private let oauthObservation: MurkioObservation

    public init(client: MurkioClient) {
        self.client = client
        // The observation is a constant so `deinit` can cancel it; the relay
        // gives its callback a way back to this controller once it exists.
        let relay = Relay()
        oauthObservation = client.observeOAuthReturn {
            Task { @MainActor in await relay.target?.takeOAuthReturn() }
        }
        relay.target = self
    }

    deinit {
        oauthObservation.cancel()
    }

    /// The email of the attempt in course, normalized.
    public var currentEmail: String { email }

    /// Calls `listener` on every change of `state`, on the main actor.
    @discardableResult
    public func observe(_ listener: @escaping (FlowState) -> Void) -> MurkioObservation {
        let id = nextListener
        nextListener += 1
        listeners[id] = listener
        return MurkioObservation { [weak self] in
            Task { @MainActor in self?.listeners[id] = nil }
        }
    }

    public func login(_ credentials: MurkioCredentials) async {
        await perform {
            self.remember(credentials)
            do {
                try await self.handle(try await self.client.api.login(email: self.email, password: self.password))
            } catch let error as MurkioError where error.code == "rsb-07" {
                try await self.client.api.sendVerification(email: self.email, locale: self.client.locale)
                self.go(.verifyEmail(email: self.email, needsPassword: false))
            }
        }
    }

    public func register(_ credentials: MurkioCredentials) async {
        await perform {
            self.remember(credentials)
            try await self.client.api.signup(email: self.email, password: self.password, locale: self.client.locale)
            self.go(.verifyEmail(email: self.email, needsPassword: false))
        }
    }

    public func confirmEmail(code: String, password: String? = nil) async {
        await perform {
            if let password, !password.isEmpty { self.password = password }
            if self.password.isEmpty {
                self.go(.verifyEmail(email: self.email, needsPassword: true))
                return
            }
            let result = try await self.client.api.confirmVerification(email: self.email, code: trimmed(code), password: self.password)
            if let result {
                try await self.handle(result)
                return
            }
            self.password = ""
            self.go(.signIn, notice: "verified.signin")
        }
    }

    public func resendEmail() async {
        await perform {
            try await self.client.api.sendVerification(email: self.email, locale: self.client.locale)
            self.state.notice = "verify.resent"
        }
    }

    public func verifyMfa(code: String) async {
        await perform {
            guard case .mfa(let token) = self.state.step else { return }
            try await self.complete(try await self.client.api.verifyMfa(mfaToken: token, code: trimmed(code)))
        }
    }

    public func confirmEnrollment(code: String) async {
        await perform {
            guard case .mfaEnroll(let token, _, _) = self.state.step else { return }
            let result = try await self.client.api.confirmMfaEnrollment(mfaToken: token, code: trimmed(code))
            self.pendingSession = result.session
            self.go(.recoveryCodes(result.recoveryCodes))
        }
    }

    /// The user saved the recovery codes: the session starts.
    public func finishRecovery() async {
        await perform {
            if let session = self.pendingSession { try await self.complete(session) }
        }
    }

    public func forgot(email: String = "") {
        guard !state.busy else { return }
        if !trimmed(email).isEmpty { self.email = normalizeEmail(email) }
        go(.forgot)
    }

    public func requestReset(email: String) async {
        await perform {
            self.email = normalizeEmail(email)
            try await self.client.api.requestPasswordReset(email: self.email, locale: self.client.locale)
            self.go(.reset(email: self.email))
        }
    }

    public func resetPassword(code: String, password: String) async {
        await perform {
            try await self.client.api.confirmPasswordReset(email: self.email, code: trimmed(code), password: password)
            self.go(.signIn, notice: "reset.done")
        }
    }

    /// Starts a social sign-in: the system browser opens the provider.
    public func oauth(provider: String, keepLogged: Bool) async {
        await perform {
            try await self.client.startOAuth(provider: provider, keepLogged: keepLogged)
        }
    }

    public func back() {
        guard !state.busy else { return }
        password = ""
        pendingSession = nil
        go(.signIn)
    }

    /// A social sign-in came back to the app: it either left a 2FA challenge
    /// for this screen to continue, or an error to show.
    public func takeOAuthReturn() async {
        if let pending = client.takePendingMfa() {
            keepLogged = pending.keepLogged
            await perform { try await self.challenge(pending.mfa) }
            return
        }
        if let error = client.takeOAuthError() {
            state.error = error
            state.notice = nil
        }
    }

    private func remember(_ credentials: MurkioCredentials) {
        email = normalizeEmail(credentials.email)
        password = credentials.password
        keepLogged = credentials.keepLogged
    }

    private func handle(_ result: LoginResult) async throws {
        switch result {
        case .session(let tokens): try await complete(tokens)
        case .mfa(let mfa): try await challenge(mfa)
        }
    }

    private func challenge(_ mfa: MfaChallenge) async throws {
        guard mfa.enrollmentRequired else {
            go(.mfa(token: mfa.token))
            return
        }
        let enrollment = try await client.api.startMfaEnrollment(mfaToken: mfa.token)
        go(.mfaEnroll(token: mfa.token, secret: enrollment.secret, otpauthUri: enrollment.otpauthUri))
    }

    private func complete(_ tokens: TokenPair) async throws {
        await client.sessions.setSession(tokens, keepLogged: keepLogged)
        password = ""
        pendingSession = nil
        go(.done)
    }

    private func go(_ step: FlowStep, notice: String? = nil) {
        state = FlowState(step: step, busy: state.busy, error: nil, notice: notice)
    }

    private func perform(_ task: () async throws -> Void) async {
        guard !state.busy else { return }
        state = FlowState(step: state.step, busy: true)
        var failure: MurkioError?
        do {
            try await task()
        } catch {
            failure = MurkioError.from(error)
        }
        state = FlowState(step: state.step, busy: false, error: failure, notice: failure == nil ? state.notice : nil)
    }
}

private final class Relay: @unchecked Sendable {
    weak var target: FlowController?
}
