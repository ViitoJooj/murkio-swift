import XCTest
@testable import MurkioIdentity

/// libs/spec/client/vectors.json is run by every client SDK. The @murkio/html
/// tests run it against the browser code, so passing here means this SDK
/// answers like the web does.
final class VectorsTests: XCTestCase {
    private func cases(_ name: String) -> [JSONValue] { vectors[name]?.array ?? [] }

    func testHashesThePublishableKey() {
        let hashes = vectors["key_hash"]?.object ?? [:]
        XCTAssertGreaterThanOrEqual(hashes.count, 4)
        for (value, hash) in hashes { XCTAssertEqual(fnv1a32(value), hash.string, value) }
    }

    func testDerivesThePkceChallenge() {
        XCTAssertFalse(cases("pkce").isEmpty)
        for entry in cases("pkce") { XCTAssertEqual(codeChallenge(entry["verifier"]?.string ?? ""), entry["challenge"]?.string) }
        XCTAssertEqual(
            sha256(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            sha256([]).map { String(format: "%02x", $0) }.joined(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testReadsTheClaimsOfAnAccessToken() {
        let entry = vectors["claims"]
        let expected = entry?["expect"]
        let claims = decodeClaims(entry?["token"]?.string ?? "")
        XCTAssertEqual(claims?.subject, expected?["sub"]?.string)
        XCTAssertEqual(claims?.sessionId, expected?["sid"]?.string)
        XCTAssertEqual(claims.map { Double($0.expiresAt) }, expected?["exp"]?.number)
        XCTAssertEqual(claims?.roles, expected?["roles"]?.strings)
        XCTAssertNil(decodeClaims("not-a-token"))
        XCTAssertNil(decodeClaims("a.b.c"))
    }

    func testParsesEveryColorForm() {
        XCTAssertFalse(cases("colors").isEmpty)
        for entry in cases("colors") {
            let color = parseColor(entry["color"])
            let rgba = (entry["rgba"]?.array ?? []).map { UInt8($0.number ?? 0) }
            XCTAssertEqual(color.map { [$0.red, $0.green, $0.blue, $0.alpha] }, rgba, entry["color"]?.string ?? "")
        }
        for bad: JSONValue in ["#12", "red", "#gggggg", "#12345", 7, .null] { XCTAssertNil(parseColor(bad)) }
        XCTAssertNil(parseColor(nil))
    }

    func testPicksTheTextOfALocale() {
        for entry in cases("text") {
            let raw = entry["text"]
            let translations = (raw?["i18n"]?.object ?? [:]).compactMapValues { $0.string }
            let text = LocalizedText(raw?["default"]?.string ?? "", translations)
            XCTAssertEqual(text.pick(entry["locale"]?.string ?? ""), entry["expect"]?.string, entry["locale"]?.string ?? "")
        }
        XCTAssertEqual(LocalizedText("x", ["pt-BR": "y"]).pick("pt_BR"), "y")
    }

    func testSpeaksTheSameBuiltInStrings() {
        for entry in cases("strings") {
            XCTAssertEqual(murkioString(entry["locale"]?.string ?? "", entry["key"]?.string ?? ""), entry["expect"]?.string)
        }
        let params = ["email": "{email}", "provider": "{provider}"]
        for locale in ["en", "pt-BR"] {
            let table = readSpec("client/strings/\(locale).json").object ?? [:]
            XCTAssertGreaterThan(table.count, 30)
            for (key, text) in table { XCTAssertEqual(murkioString(locale, key, params), text.string, key) }
        }
        XCTAssertEqual(murkioString("en", "verify.description", ["email": "a@b.c"]), "We sent a 6-digit code to a@b.c.")
    }

    func testTranslatesTheErrorCodes() {
        XCTAssertFalse(cases("errors").isEmpty)
        for entry in cases("errors") {
            XCTAssertEqual(
                translateError(entry["code"]?.string ?? "", entry["locale"]?.string ?? ""), entry["expect"]?.string,
                "\(entry["locale"]?.string ?? "") \(entry["code"]?.string ?? "")"
            )
        }
    }

    func testLaysTheCanvasOutLikeTheWeb() {
        let layouts = cases("layout")
        XCTAssertGreaterThanOrEqual(layouts.count, 20)
        for (index, entry) in layouts.enumerated() {
            let canvas = document(at: entry["document"]?.string ?? "")
            let screen = entry["screen"]?.string == "sign_up" ? canvas.signUp! : canvas.signIn
            let expected = entry["expect"]
            let at = "layout #\(index) (\(entry["document"]?.string ?? "") at \(entry["width"]?.number ?? 0))"
            let placement = place(screen, width: entry["width"]?.number ?? 0, config: config(from: entry["config"]), oauth: entry["oauth"]?.bool ?? true)

            XCTAssertEqual(placement.layout.rawValue, expected?["layout"]?.string, at)
            XCTAssertEqual(placement.frameWidth, expected?["frame"]?["width"]?.number ?? -1, accuracy: 0.01, at)
            XCTAssertEqual(placement.frameHeight, expected?["frame"]?["height"]?.number ?? -1, accuracy: 0.01, at)
            XCTAssertEqual(placement.order.map { $0.id }, expected?["order"]?.strings, at)
            XCTAssertEqual(placement.paint.map { $0.id }, expected?["paint"]?.strings, at)

            let items = expected?["items"]?.object ?? [:]
            XCTAssertEqual(Set(placement.rects.keys), Set(items.keys), at)
            for (id, want) in items {
                guard let rect = placement.rects[id] else { continue }
                XCTAssertEqual(rect.x, want["x"]?.number ?? -1, accuracy: 0.01, "\(at) \(id).x")
                XCTAssertEqual(rect.y, want["y"]?.number ?? -1, accuracy: 0.01, "\(at) \(id).y")
                XCTAssertEqual(rect.w, want["w"]?.number ?? -1, accuracy: 0.01, "\(at) \(id).w")
                XCTAssertEqual(rect.h, want["h"]?.number ?? -1, accuracy: 0.01, "\(at) \(id).h")
            }
        }
    }

    func testShowsWhatTheApplicationTurnedOn() {
        XCTAssertFalse(cases("visibility").isEmpty)
        for entry in cases("visibility") {
            let canvas = document(at: entry["document"]?.string ?? "")
            let signUp = entry["screen"]?.string == "sign_up"
            let screen = signUp ? canvas.signUp! : canvas.signIn
            let settings = config(from: entry["config"])
            let oauth = entry["oauth"]?.bool ?? true
            let at = "\(entry["document"]?.string ?? "") \(entry["screen"]?.string ?? "") oauth=\(oauth)"
            XCTAssertEqual(
                readingOrder(screen).filter { isVisible($0, config: settings, oauth: oauth) }.map { $0.id },
                entry["expect"]?["visible"]?.strings, at
            )
            XCTAssertEqual(submitAction(screen, signUp: signUp, config: settings, oauth: oauth), entry["expect"]?["submit"]?.string, at)
        }
    }

    func testFallsBackToTheDefaultCanvasWhenThePublishedOneCannotSignIn() {
        XCTAssertFalse(cases("pick_canvas").isEmpty)
        for entry in cases("pick_canvas") {
            let raw = rawDocument(at: entry["document"]?.string ?? "")
            let settings = config(from: entry["config"])
            let own = sanitizeDocument(raw).document!
            let at = "\(entry["document"]?.string ?? "") \(entry["config"]?.write() ?? "")"
            XCTAssertEqual(isUsable(own.signIn, config: settings) ? "document" : "default", entry["expect"]?.string, at)
            XCTAssertEqual(pickCanvas(raw, config: settings), isUsable(own.signIn, config: settings) ? own : defaultCanvas(), at)
        }
        XCTAssertEqual(pickCanvas(nil, config: nil), defaultCanvas())
        XCTAssertEqual(pickCanvas("nonsense", config: nil), defaultCanvas())
    }

    @MainActor
    func testWalksEveryFlowLikeTheWeb() async {
        let flows = vectors["flows"]
        let locale = flows?["locale"]?.string ?? "en"
        let refreshToken = flows?["tokens"]?["refresh_token"]?.string
        let scenarios = flows?["cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(scenarios.count, 12)

        for scenario in scenarios {
            let name = scenario["name"]?.string ?? ""
            let script = Script(name: name)
            let client = makeClient(script, locale: locale, key: "pk_vectors")
            await client.start()
            let flow = FlowController(client: client)

            for step in scenario["steps"]?.array ?? [] {
                script.expect(step["http"]?.array ?? [])
                let args = step["args"]
                let credentials = MurkioCredentials(
                    email: args?["email"]?.string ?? "", password: args?["password"]?.string ?? "",
                    keepLogged: args?["keep_logged"]?.bool == true
                )
                let call = step["call"]?.string ?? ""
                switch call {
                case "login": await flow.login(credentials)
                case "register": await flow.register(credentials)
                case "confirm_email": await flow.confirmEmail(code: args?["code"]?.string ?? "", password: args?["password"]?.string)
                case "resend_email": await flow.resendEmail()
                case "verify_mfa": await flow.verifyMfa(code: args?["code"]?.string ?? "")
                case "confirm_enrollment": await flow.confirmEnrollment(code: args?["code"]?.string ?? "")
                case "finish_recovery": await flow.finishRecovery()
                case "forgot": flow.forgot(email: args?["email"]?.string ?? "")
                case "request_reset": await flow.requestReset(email: args?["email"]?.string ?? "")
                case "reset_password": await flow.resetPassword(code: args?["code"]?.string ?? "", password: args?["password"]?.string ?? "")
                case "back": flow.back()
                default: XCTFail("unknown call \(call)")
                }
                let at = "\(name) / \(call)"
                XCTAssertEqual(script.pending, 0, "\(at) left requests unsent")
                XCTAssertEqual(script.failures, [], at)

                let state = flow.state
                let expected = step["expect"]
                XCTAssertFalse(state.busy, at)
                XCTAssertEqual(state.step.name, expected?["step"]?.string, at)
                XCTAssertEqual(state.error?.code, expected?["error"]?.string, at)
                XCTAssertEqual(state.notice, expected?["notice"]?.string, at)
                XCTAssertEqual(client.isSignedIn, expected?["signed_in"]?.bool, at)
                if expected?["signed_in"]?.bool == true {
                    XCTAssertEqual(client.currentSession?.ephemeral, expected?["ephemeral"]?.bool, at)
                    XCTAssertEqual(client.currentSession?.sessionId, expected?["session_id"]?.string, at)
                    XCTAssertEqual(client.currentSession?.refreshToken, refreshToken, at)
                }
                if let email = expected?["email"]?.string { XCTAssertEqual(flow.currentEmail, email, at) }
                switch state.step {
                case .verifyEmail(let email, let needsPassword):
                    XCTAssertEqual(email, expected?["email"]?.string, at)
                    XCTAssertEqual(needsPassword, expected?["needs_password"]?.bool, at)
                case .reset(let email):
                    XCTAssertEqual(email, expected?["email"]?.string, at)
                case .mfaEnroll(_, let secret, let otpauthUri):
                    XCTAssertEqual(secret, expected?["secret"]?.string, at)
                    XCTAssertEqual(otpauthUri, expected?["otpauth_uri"]?.string, at)
                case .recoveryCodes(let codes):
                    XCTAssertEqual(codes, expected?["codes"]?.strings, at)
                default:
                    break
                }
            }
        }
    }
}

/// A transport that plays the requests of a flow vector in order and notes anything unexpected.
private final class Script: MurkioTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let name: String
    private var queue: [JSONValue] = []
    private var problems: [String] = []

    init(name: String) {
        self.name = name
    }

    func expect(_ steps: [JSONValue]) {
        lock.lock()
        queue.append(contentsOf: steps)
        lock.unlock()
    }

    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return problems
    }

    private func next() -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return queue.isEmpty ? Optional<JSONValue>.none : queue.removeFirst()
    }

    private func fail(_ message: String) {
        lock.lock()
        problems.append(message)
        lock.unlock()
    }

    func send(_ request: MurkioHTTPRequest) async throws -> MurkioHTTPResponse {
        let path = String(request.url.dropFirst("https://api.example.com".count))
        guard let step = next() else {
            fail("unexpected \(request.method) \(path)")
            return MurkioHTTPResponse(status: 500)
        }
        if "\(request.method) \(path)" != "\(step["method"]?.string ?? "") \(step["path"]?.string ?? "")" {
            fail("expected \(step["method"]?.string ?? "") \(step["path"]?.string ?? ""), got \(request.method) \(path)")
        }
        if request.body.flatMap(JSONValue.parse) != step["body"] {
            fail("body of \(path): \(request.body ?? "nil")")
        }
        if request.headers["Authorization"] != "Bearer pk_vectors" { fail("missing key on \(path)") }
        let status = Int(step["status"]?.number ?? 0)
        if status == 0 { throw Offline() }
        let response = step["response"]
        let empty = status == 204 || response == nil || response?.isNull == true
        return MurkioHTTPResponse(status: status, body: empty ? "" : (response?.write() ?? ""))
    }
}
