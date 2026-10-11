import XCTest
@testable import MurkioIdentity

final class ClientTests: XCTestCase {
    private func bootstrapping(etag: String? = nil) -> FakeAPI {
        FakeAPI(["GET /v1/client": { call in
            if let etag, call.headers["If-None-Match"] == etag { return Answer(304) }
            return .data(bootstrapJSON(), headers: etag.map { ["etag": $0] } ?? [:])
        }])
    }

    func testOnlyAPublishableKeyIsAccepted() {
        for key in ["sk_live_secret", ""] {
            XCTAssertThrowsError(try MurkioClient(publishableKey: key, storage: MurkioMemoryStorage(), transport: FakeAPI())) { error in
                XCTAssertFalse(String(describing: error).contains("sk_live_secret"))
            }
        }
    }

    func testRequestsCarryTheKeyAndReachTheConfiguredAPI() async throws {
        let api = bootstrapping()
        let client = makeClient(api)
        let bootstrap = try await client.bootstrap()

        XCTAssertEqual(bootstrap.applicationId, "app-1")
        XCTAssertEqual(bootstrap.canvasVersion, 3)
        XCTAssertTrue(bootstrap.config.passwordEnabled)
        XCTAssertEqual(api.calls.first?.headers["Authorization"], "Bearer pk_test")
        XCTAssertEqual(client.api.apiURL, "https://api.example.com")
        XCTAssertEqual(client.keyHash, fnv1a32("pk_test"))
        XCTAssertEqual(APIClient(publishableKey: "pk_x", apiURL: "https://id.example.com//", transport: api).apiURL, "https://id.example.com")
    }

    func testTheBootstrapIsKeptForAMinuteThenRevalidatedByItsEtag() async throws {
        let clock = Clock()
        let api = bootstrapping(etag: "W/\"v1\"")
        let client = makeClient(api, clock: clock)

        let first = try await client.bootstrap()
        let again = try await client.bootstrap()
        XCTAssertEqual(first, again)
        XCTAssertEqual(api.calls.count, 1)

        clock.advance(61_000)
        let revalidated = try await client.bootstrap()
        XCTAssertEqual(revalidated, first)
        XCTAssertEqual(api.calls.count, 2)
        XCTAssertEqual(api.calls.last?.headers["If-None-Match"], "W/\"v1\"")

        clock.advance(30_000)
        _ = try await client.bootstrap()
        XCTAssertEqual(api.calls.count, 2, "a 304 renews the minute")
    }

    func testConcurrentBootstrapsShareOneRequest() async throws {
        let api = bootstrapping()
        let client = makeClient(api)
        async let first = client.bootstrap()
        async let second = client.bootstrap()
        _ = try await (first, second)
        XCTAssertEqual(api.calls.count, 1)
    }

    func testAFailedRevalidationFallsBackToTheLastBootstrap() async throws {
        let clock = Clock()
        let online = Opened()
        let api = FakeAPI(["GET /v1/client": { _ in
            if online.links.isEmpty { return .data(bootstrapJSON()) }
            throw Offline()
        }])
        let client = makeClient(api, clock: clock)
        let first = try await client.bootstrap()

        _ = online.open("offline")
        clock.advance(5 * 60_000)
        let fallback = try await client.bootstrap()
        XCTAssertEqual(fallback, first)
    }

    func testWithoutAnyBootstrapTheErrorReachesTheCaller() async {
        let client = makeClient(FakeAPI(["GET /v1/client": { _ in .error(401, "bss-01") }]))
        do {
            _ = try await client.bootstrap()
            XCTFail("expected bss-01")
        } catch let error as MurkioError {
            XCTAssertEqual(error.code, "bss-01")
            XCTAssertEqual(error.status, 401)
            XCTAssertFalse(error.localized("pt-BR").isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTheProfileIsCachedPerSessionForAMinute() async throws {
        let clock = Clock()
        let api = FakeAPI(["POST /v1/me": { _ in
            .data([
                "id": "user-1", "session_id": "session-1", "email": "ana@example.com", "email_verified": true,
                "roles": ["user", "admin"], "mfa_enabled": false, "created_at": "2029-05-01T10:00:00Z",
            ])
        }])
        let client = makeClient(api, clock: clock)
        let nobody = try await client.getUser()
        XCTAssertNil(nobody)

        let session = await client.sessions.setSession(tokenPair(nowMs: clock.time), keepLogged: true)
        let user = try await client.getUser()
        XCTAssertEqual(user?.email, "ana@example.com")
        XCTAssertEqual(user?.roles, ["user", "admin"])
        XCTAssertEqual(user?.createdAt, "2029-05-01T10:00:00Z")
        XCTAssertEqual(api.calls.first?.body, ["access_token": .string(session.accessToken)])

        _ = try await client.getUser()
        XCTAssertEqual(api.calls.count, 1)

        clock.advance(61_000)
        _ = try await client.getUser()
        XCTAssertEqual(api.calls.count, 2)

        await client.sessions.setSession(tokenPair(sessionId: "session-2", nowMs: clock.time), keepLogged: true)
        _ = try await client.getUser()
        XCTAssertEqual(api.calls.count, 3, "another session, another profile")
    }

    func testAFailedProfileIsNotCached() async throws {
        let failing = Opened()
        let api = FakeAPI(["POST /v1/me": { _ in
            failing.links.isEmpty ? .error(500, "bss-00") : .data(["id": "user-1"])
        }])
        let client = makeClient(api)
        await client.sessions.setSession(tokenPair(), keepLogged: true)

        await expectError("bss-00") { _ = try await client.getUser() }
        _ = failing.open("recovered")
        let user = try await client.getUser()
        XCTAssertEqual(user?.id, "user-1")
    }

    func testTheQueryOfALinkIsReadByHand() {
        XCTAssertEqual(queryOf("https://app.example.com/cb?code=a%20b&state=x%2Fy#frag"), ["code": "a b", "state": "x/y"])
        XCTAssertEqual(queryOf("https://app.example.com/cb"), [:])
        XCTAssertEqual(queryOf("https://app.example.com/?flag&a=1&"), ["flag": "", "a": "1"])
    }

    // Social sign-in.

    private let redirect = "https://app.example.com/auth/callback"

    private func oauthAPI() -> FakeAPI {
        FakeAPI(["POST /v1/oauth/google/authorize": { _ in .data(["authorization_url": "https://accounts.example.com/o/auth?x=1"]) }])
    }

    private func attempt(_ client: MurkioClient, _ storage: MurkioMemoryStorage) -> JSONValue? {
        storage.read("murkio.\(client.keyHash).oauth").flatMap(JSONValue.parse)
    }

    func testSocialSignInStartsWithPkceAndOpensTheProvider() async throws {
        let api = oauthAPI()
        let storage = MurkioMemoryStorage()
        let opened = Opened()
        let client = makeClient(api, storage: storage, oauthRedirectURL: redirect, opened: opened)
        XCTAssertTrue(client.oauthEnabled)
        try await client.startOAuth(provider: "google", keepLogged: true)

        let body = api.calls.first?.body
        let stored = attempt(client, storage)
        XCTAssertEqual(body?["redirect_url"]?.string, redirect)
        XCTAssertEqual(body?["code_challenge_method"]?.string, "S256")
        XCTAssertEqual(body?["code_challenge"]?.string, codeChallenge(stored?["verifier"]?.string ?? ""))
        XCTAssertEqual(body?["state"], stored?["state"])
        XCTAssertEqual(stored?["verifier"]?.string?.count, 64)
        XCTAssertEqual(stored?["state"]?.string?.count, 32)
        XCTAssertEqual(stored?["keepLogged"]?.bool, true)
        XCTAssertEqual(opened.links, ["https://accounts.example.com/o/auth?x=1"])
    }

    func testSocialSignInIsRefusedWithoutAReturnLinkOrABrowser() async {
        let api = oauthAPI()
        let none = makeClient(api)
        XCTAssertFalse(none.oauthEnabled)
        await expectError("oauth.provider_disabled") { try await none.startOAuth(provider: "google", keepLogged: true) }
        XCTAssertTrue(api.calls.isEmpty)

        let storage = MurkioMemoryStorage()
        let closed = makeClient(api, storage: storage, oauthRedirectURL: redirect, opened: Opened(succeeds: false))
        await expectError("oauth.server_error") { try await closed.startOAuth(provider: "google", keepLogged: true) }
        XCTAssertTrue(storage.keys.isEmpty)
    }

    func testAnAuthorizationLinkThatIsNotHttpsIsNeverOpened() async {
        let opened = Opened()
        let api = FakeAPI(["POST /v1/oauth/google/authorize": { _ in .data(["authorization_url": "intent://evil"]) }])
        let client = makeClient(api, oauthRedirectURL: redirect, opened: opened)
        await expectError("oauth.server_error") { try await client.startOAuth(provider: "google", keepLogged: true) }
        XCTAssertTrue(opened.links.isEmpty)
    }

    func testTheReturnWithTheCodeBecomesASession() async throws {
        let api = oauthAPI().on("POST /v1/oauth/token") { _ in .data(tokens()) }
        let storage = MurkioMemoryStorage()
        let client = makeClient(api, storage: storage, oauthRedirectURL: redirect, opened: Opened())
        try await client.startOAuth(provider: "google", keepLogged: false)
        let stored = attempt(client, storage)

        let handled = await client.handleRedirect("\(redirect)?code=oac_1&state=\(stored?["state"]?.string ?? "")")

        XCTAssertTrue(handled)
        XCTAssertEqual(api.calls.last?.body, ["code": "oac_1", "code_verifier": stored?["verifier"] ?? .null])
        XCTAssertTrue(client.isSignedIn)
        XCTAssertEqual(client.currentSession?.ephemeral, true)
        XCTAssertFalse(storage.keys.contains { $0.hasSuffix(".oauth") })
    }

    func testALinkWithAnotherStateIsNotOurs() async throws {
        let api = oauthAPI()
        let storage = MurkioMemoryStorage()
        let client = makeClient(api, storage: storage, oauthRedirectURL: redirect, opened: Opened())
        try await client.startOAuth(provider: "google", keepLogged: true)

        for link in ["\(redirect)?code=x&state=other", "\(redirect)?code=x", "https://app.example.com/"] {
            let handled = await client.handleRedirect(link)
            XCTAssertFalse(handled, link)
        }
        XCTAssertEqual(api.calls.count, 1)
        XCTAssertFalse(storage.keys.isEmpty, "the attempt is still open")
    }

    @MainActor
    func testAnErrorReturnReachesTheSignInScreenOnce() async throws {
        let storage = MurkioMemoryStorage()
        let client = makeClient(oauthAPI(), storage: storage, oauthRedirectURL: redirect, opened: Opened())
        try await client.startOAuth(provider: "google", keepLogged: true)
        let flow = FlowController(client: client)

        await client.handleRedirect("\(redirect)?error=access_denied&state=\(attempt(client, storage)?["state"]?.string ?? "")")
        await eventually("the error on the sign-in screen") { await MainActor.run { flow.state.error != nil } }

        XCTAssertEqual(flow.state.error?.code, "oauth.access_denied")
        XCTAssertNil(client.takeOAuthError())
        XCTAssertFalse(client.isSignedIn)
    }

    @MainActor
    func testATwoFactorChallengeContinuesOnTheSignInScreen() async throws {
        let api = oauthAPI()
            .on("POST /v1/oauth/token") { _ in .data(["mfa": ["token": "mfa_9", "enrollment_required": false]]) }
            .on("POST /v1/mfa/challenge/verify") { _ in .data(tokens()) }
        let storage = MurkioMemoryStorage()
        let client = makeClient(api, storage: storage, oauthRedirectURL: redirect, opened: Opened())
        try await client.startOAuth(provider: "google", keepLogged: false)
        let flow = FlowController(client: client)

        await client.handleRedirect("\(redirect)?code=oac_2&state=\(attempt(client, storage)?["state"]?.string ?? "")")
        await eventually("the two-step screen") { await MainActor.run { flow.state.step.name == "mfa" } }

        await flow.verifyMfa(code: "123456")
        XCTAssertEqual(flow.state.step, .done)
        XCTAssertEqual(client.currentSession?.ephemeral, true)
    }
}
