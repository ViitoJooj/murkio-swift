import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A request the SDK sends to the identity API.
public struct MurkioHTTPRequest: Sendable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    /// The JSON body, or nil.
    public let body: String?
}

/// The answer to a `MurkioHTTPRequest`. Header names are lowercase.
public struct MurkioHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: String

    public init(status: Int, headers: [String: String] = [:], body: String = "") {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// How the SDK reaches the network. The default uses `URLSession`; an app (or
/// a test) can pass its own. Throw any error when the request got no answer:
/// the SDK reports it as the `network` error.
public protocol MurkioTransport: Sendable {
    func send(_ request: MurkioHTTPRequest) async throws -> MurkioHTTPResponse
}

/// The secret and the link of a 2FA enrollment.
public struct MfaEnrollment: Equatable, Sendable {
    public let secret: String
    public let otpauthUri: String
}

/// The recovery codes and the session of a confirmed 2FA enrollment.
public struct MfaEnrollmentResult: Equatable, Sendable {
    public let recoveryCodes: [String]
    public let session: TokenPair
}

struct BootstrapResponse {
    let notModified: Bool
    let etag: String?
    let data: ClientBootstrap?
}

struct APIResponse {
    let status: Int
    let data: JSONValue?
    let headers: [String: String]
}

/// APIClient talks to the identity API with the publishable key. Every method
/// maps one route; errors come back as `MurkioError` with the API code. It
/// holds no state: tokens live in the session manager.
public struct APIClient: Sendable {
    /// Where the identity API lives unless the app says otherwise.
    public static let defaultURL = "https://api.mukio.com"

    /// The base URL of the identity API, without a trailing slash.
    public let apiURL: String
    private let publishableKey: String
    private let transport: MurkioTransport

    init(publishableKey: String, apiURL: String?, transport: MurkioTransport) {
        var url = apiURL ?? APIClient.defaultURL
        while url.hasSuffix("/") { url.removeLast() }
        self.apiURL = url
        self.publishableKey = publishableKey
        self.transport = transport
    }

    func request(_ method: String, _ path: String, body: JSONValue? = nil, headers: [String: String] = [:]) async throws -> APIResponse {
        var all = headers
        all["Authorization"] = "Bearer \(publishableKey)"
        if body != nil { all["Content-Type"] = "application/json" }

        let response: MurkioHTTPResponse
        do {
            response = try await transport.send(MurkioHTTPRequest(method: method, url: apiURL + path, headers: all, body: body?.write()))
        } catch let error as MurkioError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No answer at all (offline, DNS, TLS, timeout): the one error the app may want to retry.
            throw MurkioError("network", message: String(describing: error))
        }

        let json = response.status == 204 || response.status == 304 ? nil : JSONValue.parse(response.body)
        if !(200...299).contains(response.status), response.status != 304 {
            throw MurkioError.fromResponse(status: response.status, body: json)
        }
        return APIResponse(status: response.status, data: json?["data"], headers: response.headers)
    }

    func bootstrap(etag: String?) async throws -> BootstrapResponse {
        let response = try await request("GET", "/v1/client", headers: etag.map { ["If-None-Match": $0] } ?? [:])
        let data = try response.data.flatMap { $0.isNull ? nil : try ClientBootstrap(json: $0) }
        return BootstrapResponse(notModified: response.status == 304, etag: response.headers["etag"], data: data)
    }

    public func signup(email: String, password: String, locale: String) async throws {
        _ = try await request("POST", "/v1/signup", body: ["email": .string(email), "password": .string(password), "locale": .string(locale)])
    }

    public func login(email: String, password: String) async throws -> LoginResult {
        try LoginResult(json: try await request("POST", "/v1/login", body: ["email": .string(email), "password": .string(password)]).data)
    }

    public func sendVerification(email: String, locale: String) async throws {
        _ = try await request("POST", "/v1/email/verification", body: ["email": .string(email), "locale": .string(locale)])
    }

    /// Confirms the email. Returns the session (or the 2FA challenge), or nil
    /// when the application does not sign in on verify.
    public func confirmVerification(email: String, code: String, password: String) async throws -> LoginResult? {
        let response = try await request(
            "POST", "/v1/email/verification/confirm",
            body: ["email": .string(email), "code": .string(code), "password": .string(password)]
        )
        guard response.status != 204, let data = response.data, !data.isNull else { return nil }
        return try LoginResult(json: data)
    }

    public func requestPasswordReset(email: String, locale: String) async throws {
        _ = try await request("POST", "/v1/password/reset", body: ["email": .string(email), "locale": .string(locale)])
    }

    public func confirmPasswordReset(email: String, code: String, password: String) async throws {
        _ = try await request(
            "POST", "/v1/password/reset/confirm",
            body: ["email": .string(email), "code": .string(code), "password": .string(password)]
        )
    }

    public func refresh(_ refreshToken: String) async throws -> TokenPair {
        try TokenPair(json: try await request("POST", "/v1/token/refresh", body: ["refresh_token": .string(refreshToken)]).data)
    }

    public func logout(_ refreshToken: String) async throws {
        _ = try await request("POST", "/v1/logout", body: ["refresh_token": .string(refreshToken)])
    }

    public func me(accessToken: String) async throws -> MurkioUser {
        try MurkioUser(json: try await request("POST", "/v1/me", body: ["access_token": .string(accessToken)]).data)
    }

    public func verifyMfa(mfaToken: String, code: String) async throws -> TokenPair {
        try TokenPair(json: try await request("POST", "/v1/mfa/challenge/verify", body: ["mfa_token": .string(mfaToken), "code": .string(code)]).data)
    }

    public func startMfaEnrollment(mfaToken: String) async throws -> MfaEnrollment {
        let data = try await request("POST", "/v1/mfa/challenge/enroll", body: ["mfa_token": .string(mfaToken)]).data
        guard let secret = data?["secret"]?.string, let uri = data?["otpauth_uri"]?.string else {
            throw MurkioError("unknown", message: "unexpected enrollment")
        }
        return MfaEnrollment(secret: secret, otpauthUri: uri)
    }

    public func confirmMfaEnrollment(mfaToken: String, code: String) async throws -> MfaEnrollmentResult {
        let data = try await request("POST", "/v1/mfa/challenge/enroll/confirm", body: ["mfa_token": .string(mfaToken), "code": .string(code)]).data
        guard let data, data.object != nil else { throw MurkioError("unknown", message: "unexpected enrollment") }
        return MfaEnrollmentResult(recoveryCodes: data["recovery_codes"]?.strings ?? [], session: try TokenPair(json: data["session"]))
    }

    /// Asks where to send the user for a social sign-in.
    public func authorizeOAuth(provider: String, redirectURL: String, state: String, codeChallenge: String) async throws -> String {
        let name = provider.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? provider
        let data = try await request(
            "POST", "/v1/oauth/\(name)/authorize",
            body: [
                "redirect_url": .string(redirectURL),
                "state": .string(state),
                "code_challenge": .string(codeChallenge),
                "code_challenge_method": "S256",
            ]
        ).data
        guard let url = data?["authorization_url"]?.string else { throw MurkioError("unknown", message: "unexpected authorization") }
        return url
    }

    public func exchangeOAuthCode(code: String, codeVerifier: String) async throws -> LoginResult {
        try LoginResult(json: try await request("POST", "/v1/oauth/token", body: ["code": .string(code), "code_verifier": .string(codeVerifier)]).data)
    }
}

/// The default transport: a `URLSession` without cookies or cache.
public final class URLSessionTransport: MurkioTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: MurkioHTTPRequest) async throws -> MurkioHTTPResponse {
        guard let url = URL(string: request.url) else { throw MurkioError("network", message: "invalid url") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = request.body.map { Data($0.utf8) }

        // A data task with a continuation, not `data(for:)`: this form exists
        // on every platform and Swift version the package supports.
        let session = self.session
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: error ?? MurkioError("network", message: "no response"))
                    return
                }
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    headers[String(describing: name).lowercased()] = String(describing: value)
                }
                let body = String(decoding: data ?? Data(), as: UTF8.self)
                continuation.resume(returning: MurkioHTTPResponse(status: http.statusCode, headers: headers, body: body))
            }
            task.resume()
        }
    }
}
