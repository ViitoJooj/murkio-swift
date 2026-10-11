import Foundation
import XCTest
@testable import MurkioIdentity

/// libs/spec, shared with the service and the other SDKs.
let specDirectory: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("spec")
}()

func readSpec(_ path: String) -> JSONValue {
    guard let text = try? String(contentsOf: specDirectory.appendingPathComponent(path), encoding: .utf8),
          let value = JSONValue.parse(text)
    else { fatalError("cannot read spec file \(path)") }
    return value
}

/// A raw document from a vector reference (`file.json` or `file.json#field`).
func rawDocument(at ref: String) -> JSONValue {
    let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
    let value = readSpec(parts[0])
    return parts.count > 1 ? (value[parts[1]] ?? .null) : value
}

/// The same document after the SDK's own validation.
func document(at ref: String, file: StaticString = #filePath, line: UInt = #line) -> CanvasDocument {
    let result = sanitizeDocument(rawDocument(at: ref))
    XCTAssertEqual(result.problems, [], ref, file: file, line: line)
    return result.document!
}

let vectors = readSpec("client/vectors.json")

func config(from json: JSONValue?) -> PublicConfig? {
    guard let json, !json.isNull else { return nil }
    return PublicConfig(json: json)
}

/// One request the fake API received.
struct Call: Sendable {
    let method: String
    let path: String
    let body: JSONValue?
    let headers: [String: String]
}

/// What the fake API answers.
struct Answer: Sendable {
    var status: Int
    var body: JSONValue?
    var headers: [String: String] = [:]

    init(_ status: Int, body: JSONValue? = nil, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// An API error with one detail.
    static func error(_ status: Int, _ code: String) -> Answer {
        Answer(status, body: ["details": [["code": .string(code), "message": .string(code)]]])
    }

    /// A `{"data": ...}` answer.
    static func data(_ data: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> Answer {
        Answer(status, body: ["data": data], headers: headers)
    }
}

struct Offline: Error {}

/// A transport that answers from a table of "METHOD /path" handlers and records the calls. A handler may throw.
final class FakeAPI: MurkioTransport, @unchecked Sendable {
    typealias Handler = @Sendable (Call) async throws -> Answer

    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private var recorded: [Call] = []

    init(_ routes: [String: Handler] = [:]) {
        self.routes = routes
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func to(_ path: String) -> [Call] {
        calls.filter { $0.path == path }
    }

    @discardableResult
    func on(_ key: String, _ handler: @escaping Handler) -> FakeAPI {
        lock.lock()
        routes[key] = handler
        lock.unlock()
        return self
    }

    /// Notes the call and returns its handler (locks are taken outside the async code).
    private func record(_ call: Call) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return routes["\(call.method) \(call.path)"]
    }

    func send(_ request: MurkioHTTPRequest) async throws -> MurkioHTTPResponse {
        let prefix = "https://api.example.com"
        let path = request.url.hasPrefix(prefix) ? String(request.url.dropFirst(prefix.count)) : request.url
        let call = Call(method: request.method, path: path, body: request.body.flatMap(JSONValue.parse), headers: request.headers)
        guard let handler = record(call) else {
            let body: JSONValue = ["details": [["code": "test-404", "message": .string(path)]]]
            return MurkioHTTPResponse(status: 404, body: body.write())
        }
        let answer = try await handler(call)
        let empty = answer.status == 204 || answer.status == 304 || answer.body == nil
        return MurkioHTTPResponse(status: answer.status, headers: answer.headers, body: empty ? "" : (answer.body?.write() ?? ""))
    }
}

func jwt(_ claims: JSONValue) -> String {
    func encode(_ value: JSONValue) -> String { base64URLEncode(Array(value.write().utf8)) }
    return "\(encode(["alg": "EdDSA", "typ": "JWT"])).\(encode(claims)).signature"
}

private let counter = Counter()

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// A fresh token pair as the API returns it.
func tokens(expiresIn: Int = 900, sessionId: String = "session-1", nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> JSONValue {
    let number = counter.next()
    let seconds = Double(nowMs / 1000)
    return [
        "access_token": .string(jwt([
            "iss": "enterprise-auth", "sub": "user-1", "aud": "app-1", "sid": .string(sessionId), "roles": ["user"],
            "iat": .number(seconds), "exp": .number(seconds + Double(expiresIn)), "jti": .string("j\(number)"),
        ])),
        "token_type": "Bearer",
        "expires_in": .number(Double(expiresIn)),
        "refresh_token": .string("rt_\(number)"),
        "session_id": .string(sessionId),
    ]
}

func tokenPair(expiresIn: Int = 900, sessionId: String = "session-1", nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> TokenPair {
    try! TokenPair(json: tokens(expiresIn: expiresIn, sessionId: sessionId, nowMs: nowMs))
}

func bootstrapJSON(document: JSONValue? = nil, password: Bool = true, providers: [String] = [], version: Int = 3) -> JSONValue {
    [
        "application_id": "app-1",
        "issuer": "enterprise-auth",
        "jwks_url": "/v1/applications/app-1/jwks.json",
        "config": [
            "methods": ["password": .bool(password)],
            "mfa": ["mode": "optional"],
            "oauth_providers": .array(providers.map { .string($0) }),
            "signup": ["login_on_verify": true],
        ],
        "canvas": ["version": .number(Double(version)), "document": document ?? readSpec("canvas/default.json")],
    ]
}

/// A clock the test moves by hand.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_900_000_000_000

    var time: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ milliseconds: Int64) {
        lock.lock()
        value += milliseconds
        lock.unlock()
    }
}

/// The links a test client was asked to open.
final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    let succeeds: Bool

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    var links: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func open(_ link: String) -> Bool {
        lock.lock()
        values.append(link)
        lock.unlock()
        return succeeds
    }
}

/// A client that talks to `api`, keeps the session in memory and takes the
/// time from `clock`. `foreground` false keeps the refresh timer from calling
/// the API behind the test's back.
func makeClient(
    _ api: MurkioTransport,
    storage: MurkioStorage = MurkioMemoryStorage(),
    locale: String? = "en",
    oauthRedirectURL: String? = nil,
    opened: Opened? = nil,
    clock: Clock? = nil,
    foreground: Bool = false,
    key: String = "pk_test"
) -> MurkioClient {
    try! MurkioClient(
        publishableKey: key,
        apiURL: "https://api.example.com",
        locale: locale,
        oauthRedirectURL: oauthRedirectURL,
        storage: storage,
        transport: api,
        opener: { link in opened?.open(link) ?? false },
        now: { clock?.time ?? Int64(Date().timeIntervalSince1970 * 1000) },
        isForeground: { foreground }
    )
}

/// Holds requests until the test lets them through.
actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Waits until `condition` holds, giving other tasks time to run.
func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () async -> Bool) async {
    for _ in 0..<500 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

func expectError(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(code)", file: file, line: line)
    } catch let error as MurkioError {
        XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}
