import Foundation

/// The tokens of a session, as the API returns them.
public struct TokenPair: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    /// Seconds until the access token expires.
    public let expiresIn: Int
    public let sessionId: String

    public init(accessToken: String, refreshToken: String, expiresIn: Int, sessionId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.sessionId = sessionId
    }

    /// Reads a token pair; anything else is an `unknown` error.
    init(json: JSONValue?) throws {
        guard let access = json?["access_token"]?.string, let refresh = json?["refresh_token"]?.string,
            let expires = json?["expires_in"]?.number, let session = json?["session_id"]?.string
        else { throw MurkioError("unknown", message: "unexpected token response") }
        self.init(accessToken: access, refreshToken: refresh, expiresIn: Int(expires), sessionId: session)
    }
}

/// The two-step verification the API asks for before giving a session.
public struct MfaChallenge: Equatable, Sendable {
    public let token: String
    /// The application requires 2FA and the user has no authenticator yet.
    public let enrollmentRequired: Bool
}

/// What a sign-in returns: a session, or the 2FA challenge to pass first.
public enum LoginResult: Equatable, Sendable {
    case session(TokenPair)
    case mfa(MfaChallenge)

    init(json: JSONValue?) throws {
        if let token = json?["mfa"]?["token"]?.string {
            self = .mfa(MfaChallenge(token: token, enrollmentRequired: json?["mfa"]?["enrollment_required"]?.bool == true))
        } else {
            self = .session(try TokenPair(json: json))
        }
    }
}

/// The signed-in user's profile (`POST /v1/me`).
public struct MurkioUser: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    /// Nil for a user that only has a social sign-in without an email.
    public let email: String?
    public let emailVerified: Bool
    public let roles: [String]
    public let mfaEnabled: Bool
    /// RFC 3339, as the API sends it.
    public let createdAt: String?

    init(json: JSONValue?) throws {
        guard let id = json?["id"]?.string else { throw MurkioError("unknown", message: "unexpected profile") }
        self.id = id
        sessionId = json?["session_id"]?.string ?? ""
        email = json?["email"]?.string
        emailVerified = json?["email_verified"]?.bool == true
        roles = json?["roles"]?.strings ?? []
        mfaEnabled = json?["mfa_enabled"]?.bool == true
        createdAt = json?["created_at"]?.string
    }
}

/// What the application turned on, as the login screen needs to know.
public struct PublicConfig: Equatable, Sendable {
    public let passwordEnabled: Bool
    /// `off`, `optional` or `required`.
    public let mfaMode: String
    public let oauthProviders: [String]
    public let loginOnVerify: Bool

    public init(passwordEnabled: Bool = true, mfaMode: String = "optional", oauthProviders: [String] = [], loginOnVerify: Bool = true) {
        self.passwordEnabled = passwordEnabled
        self.mfaMode = mfaMode
        self.oauthProviders = oauthProviders
        self.loginOnVerify = loginOnVerify
    }

    init(json: JSONValue?) {
        guard let json, json.object != nil else {
            self.init()
            return
        }
        self.init(
            passwordEnabled: json["methods"]?["password"]?.bool != false,
            mfaMode: json["mfa"]?["mode"]?.string ?? "off",
            oauthProviders: json["oauth_providers"]?.strings ?? [],
            loginOnVerify: json["signup"]?["login_on_verify"]?.bool != false
        )
    }
}

/// The answer of `GET /v1/client`: the application behind the publishable
/// key, its public config and the published canvas.
public struct ClientBootstrap: Equatable, Sendable {
    public let applicationId: String
    public let config: PublicConfig
    /// 0 is the default canvas: the application never published one.
    public let canvasVersion: Int
    /// The canvas as it came from the API. It is validated again before it is drawn.
    public let canvasDocument: JSONValue

    init(json: JSONValue?) throws {
        guard let id = json?["application_id"]?.string, let canvas = json?["canvas"], canvas.object != nil else {
            throw MurkioError("unknown", message: "unexpected bootstrap")
        }
        applicationId = id
        config = PublicConfig(json: json?["config"])
        canvasVersion = Int(canvas["version"]?.number ?? 0)
        canvasDocument = canvas["document"] ?? .null
    }
}

/// The claims of an access token the app may want to read.
public struct AccessClaims: Equatable, Sendable {
    /// The user id.
    public let subject: String
    public let sessionId: String
    /// Seconds since the epoch.
    public let expiresAt: Int
    public let roles: [String]
}

/// Reads the claims of an access token **without checking its signature**.
/// The app only uses them for display and timing; every decision that matters
/// is taken by the API or by a backend that verifies the token.
public func decodeClaims(_ token: String) -> AccessClaims? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2, let bytes = base64Decode(String(parts[1])) else { return nil }
    guard let claims = JSONValue.parse(String(decoding: bytes, as: UTF8.self)),
        let exp = claims["exp"]?.number, let sub = claims["sub"]?.string
    else { return nil }
    return AccessClaims(subject: sub, sessionId: claims["sid"]?.string ?? "", expiresAt: Int(exp), roles: claims["roles"]?.strings ?? [])
}
