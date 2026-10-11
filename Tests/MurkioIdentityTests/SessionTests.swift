import XCTest
@testable import MurkioIdentity

final class SessionTests: XCTestCase {
    private var clock = Clock()
    private var storage = MurkioMemoryStorage()
    private let key = "murkio.\(fnv1a32("pk_test")).session"

    override func setUp() {
        clock = Clock()
        storage = MurkioMemoryStorage()
    }

    private func start(_ api: FakeAPI, on other: MurkioStorage? = nil, foreground: Bool = false) async -> MurkioClient {
        let client = makeClient(api, storage: other ?? storage, clock: clock, foreground: foreground)
        await client.start()
        return client
    }

    @discardableResult
    private func signIn(_ client: MurkioClient, keepLogged: Bool = true, id: String = "session-1") async -> MurkioSession {
        await client.sessions.setSession(tokenPair(sessionId: id, nowMs: clock.time), keepLogged: keepLogged)
    }

    private func refreshing() -> FakeAPI {
        let clock = self.clock
        return FakeAPI(["POST /v1/token/refresh": { _ in .data(tokens(nowMs: clock.time)) }])
    }

    func testStoresOneRecordNamedAfterThePublishableKey() async {
        let client = await start(FakeAPI())
        let session = await signIn(client)

        let record = storage.read(key).flatMap(JSONValue.parse)
        XCTAssertEqual(Set(record?.object?.keys.map { $0 } ?? []), ["accessToken", "refreshToken", "expiresAt", "sessionId", "ephemeral"])
        XCTAssertEqual(record?["refreshToken"]?.string, session.refreshToken)
        XCTAssertEqual(record?["ephemeral"]?.bool, false)
        XCTAssertEqual(record?["expiresAt"]?.number, Double(clock.time + 900_000))
        XCTAssertTrue(client.isSignedIn)
        XCTAssertEqual(session.userId, "user-1")
        XCTAssertEqual(session.roles, ["user"])
    }

    func testGetTokenReturnsTheCurrentTokenWhileItIsFresh() async throws {
        let api = FakeAPI()
        let client = await start(api)
        let session = await signIn(client)

        clock.advance(869_000)
        let token = try await client.getToken()
        XCTAssertEqual(token, session.accessToken)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testGetTokenRefreshesATokenAboutToExpireAndKeepsTheChoice() async throws {
        let api = refreshing()
        let client = await start(api)
        let first = await signIn(client, keepLogged: false)

        clock.advance(880_000)
        let token = try await client.getToken()

        XCTAssertEqual(api.calls.count, 1)
        XCTAssertEqual(api.calls.first?.body, ["refresh_token": .string(first.refreshToken)])
        XCTAssertNotEqual(token, first.accessToken)
        XCTAssertEqual(client.currentSession?.ephemeral, true)
        XCTAssertEqual(storage.read(key).flatMap(JSONValue.parse)?["refreshToken"]?.string, client.currentSession?.refreshToken)
    }

    func testCallersThatAskAtTheSameTimeShareOneRefresh() async throws {
        let gate = Gate()
        let clock = self.clock
        let api = FakeAPI(["POST /v1/token/refresh": { _ in
            await gate.wait()
            return .data(tokens(nowMs: clock.time))
        }])
        let client = await start(api)
        await signIn(client)
        clock.advance(890_000)

        let pending = (0..<3).map { _ in Task { try await client.getToken() } }
        await eventually("the refresh request") { api.calls.count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await gate.release()
        var results: Set<String?> = []
        for task in pending { results.insert(try await task.value) }

        XCTAssertEqual(api.to("/v1/token/refresh").count, 1)
        XCTAssertEqual(results.count, 1)
    }

    func testACancelledCallerDoesNotCancelTheRefresh() async throws {
        let gate = Gate()
        let clock = self.clock
        let api = FakeAPI(["POST /v1/token/refresh": { _ in
            await gate.wait()
            return .data(tokens(nowMs: clock.time))
        }])
        let client = await start(api)
        let first = await signIn(client)
        clock.advance(890_000)

        let impatient = Task { try await client.getToken() }
        await eventually("the refresh request") { api.calls.count == 1 }
        impatient.cancel()
        await gate.release()

        await eventually("the renewed session") { client.currentSession?.refreshToken != first.refreshToken }
        XCTAssertEqual(api.calls.count, 1)
        let token = try await client.getToken()
        XCTAssertEqual(token, client.currentSession?.accessToken)
    }

    func testASessionEndedByTheAPISignsTheUserOut() async throws {
        for code in ["rsb-02", "rsb-03", "rsb-05"] {
            storage = MurkioMemoryStorage()
            let client = await start(FakeAPI(["POST /v1/token/refresh": { _ in .error(401, code) }]))
            await signIn(client)
            clock.advance(890_000)

            let token = try await client.getToken()
            XCTAssertNil(token, code)
            XCTAssertFalse(client.isSignedIn, code)
            XCTAssertTrue(storage.keys.isEmpty, code)
        }
    }

    func testObserversHearAboutSignInsAndSignOuts() async {
        let client = await start(FakeAPI(["POST /v1/logout": { _ in Answer(204) }]))
        let seen = Opened()
        let observation = client.observeSession { session in _ = seen.open(session?.sessionId ?? "none") }

        await signIn(client, id: "observed")
        await client.signOut()
        observation.cancel()
        await signIn(client, id: "not-heard")

        XCTAssertEqual(seen.links, ["observed", "none"])
    }

    func testANetworkErrorKeepsTheSessionAndIsReported() async {
        let client = await start(FakeAPI(["POST /v1/token/refresh": { _ in throw Offline() }]))
        let session = await signIn(client)
        clock.advance(890_000)

        await expectError("network") { _ = try await client.getToken() }
        XCTAssertEqual(client.currentSession, session)
        XCTAssertFalse(storage.keys.isEmpty)

        await client.sessions.refreshIfDue()
        XCTAssertEqual(client.currentSession, session)
    }

    func testAnotherErrorOnRefreshKeepsTheSessionToo() async {
        let client = await start(FakeAPI(["POST /v1/token/refresh": { _ in .error(429, "rsb-01") }]))
        await signIn(client)
        clock.advance(890_000)

        await expectError("rsb-01") { _ = try await client.getToken() }
        XCTAssertTrue(client.isSignedIn)
    }

    func testAKeptSessionIsRestoredByTheNextRunOfTheApp() async {
        let session = await signIn(await start(FakeAPI()), id: "kept-session")

        let api = FakeAPI()
        let second = await start(api)
        XCTAssertEqual(second.currentSession, session)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testAnEphemeralSessionLeftByAPreviousRunIsLoggedOutAndDeleted() async {
        storage.write(key, JSONValue.object([
            "accessToken": "old-access", "refreshToken": "old-refresh", "expiresAt": .number(Double(clock.time + 300_000)),
            "sessionId": "session-of-a-previous-run", "ephemeral": true,
        ]).write())
        let api = FakeAPI(["POST /v1/logout": { _ in Answer(204) }])

        let client = await start(api)
        await eventually("the logout") { api.calls.count == 1 }

        XCTAssertFalse(client.isSignedIn)
        XCTAssertTrue(storage.keys.isEmpty)
        XCTAssertEqual(api.calls.first?.path, "/v1/logout")
        XCTAssertEqual(api.calls.first?.body, ["refresh_token": "old-refresh"])
    }

    func testAnEphemeralSessionOfThisRunSurvivesASecondClient() async {
        let session = await signIn(await start(FakeAPI()), keepLogged: false, id: "this-run")

        let api = FakeAPI()
        let second = await start(api)
        XCTAssertEqual(second.currentSession, session)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testARecordThatCannotBeReadMeansNobodyIsSignedIn() async {
        storage.write(key, "{not json")
        let first = await start(FakeAPI())
        XCTAssertFalse(first.isSignedIn)

        storage.write(key, JSONValue.object(["accessToken": "only-this"]).write())
        let second = await start(FakeAPI())
        XCTAssertFalse(second.isSignedIn)
    }

    func testSigningOutDeletesTheRecordBeforeCallingTheAPI() async {
        let storage = self.storage
        let seen = Opened()
        let api = FakeAPI(["POST /v1/logout": { _ in
            _ = seen.open(storage.keys.isEmpty ? "deleted" : "still stored")
            return .error(500, "bss-00")
        }])
        let client = await start(api)
        let session = await signIn(client)

        await client.signOut()

        XCTAssertEqual(seen.links, ["deleted"])
        XCTAssertFalse(client.isSignedIn)
        XCTAssertEqual(api.calls.first?.body, ["refresh_token": .string(session.refreshToken)])
    }

    func testSigningOutDuringARefreshDoesNotBringTheSessionBack() async throws {
        let gate = Gate()
        let renewed = tokens(nowMs: clock.time)
        let api = FakeAPI([
            "POST /v1/token/refresh": { _ in
                await gate.wait()
                return .data(renewed)
            },
            "POST /v1/logout": { _ in Answer(204) },
        ])
        let client = await start(api)
        await signIn(client)
        clock.advance(890_000)

        let refreshing = Task { try await client.getToken() }
        await eventually("the refresh request") { api.to("/v1/token/refresh").count == 1 }
        await client.signOut()
        await gate.release()

        let token = try await refreshing.value
        XCTAssertNil(token)
        await eventually("the logout of the renewed tokens") {
            api.to("/v1/logout").contains { $0.body?["refresh_token"] == renewed["refresh_token"] }
        }
        XCTAssertFalse(client.isSignedIn)
        XCTAssertTrue(storage.keys.isEmpty)
    }

    func testATokenRenewedElsewhereIsAdoptedInsteadOfRefreshedAgain() async throws {
        let api = FakeAPI()
        let client = await start(api)
        let session = await signIn(client)
        clock.advance(890_000)

        // Another process of the app already used the refresh token.
        let renewed = MurkioSession(
            accessToken: "renewed-access", refreshToken: "renewed-refresh", expiresAt: clock.time + 900_000,
            sessionId: session.sessionId, ephemeral: false
        )
        storage.write(key, renewed.toJSON())

        let token = try await client.getToken()
        XCTAssertEqual(token, "renewed-access")
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testRefreshIfDueOnlyCallsTheAPIInsideTheMargin() async {
        let api = refreshing()
        let client = await start(api)
        await signIn(client)

        clock.advance(800_000)
        await client.sessions.refreshIfDue()
        XCTAssertTrue(api.calls.isEmpty)

        clock.advance(20_000)
        await client.sessions.refreshIfDue()
        XCTAssertEqual(api.calls.count, 1)
    }

    func testARestoredSessionAboutToExpireIsRenewedOnStart() async {
        await signIn(await start(FakeAPI()), id: "old-but-kept")
        clock.advance(20 * 60_000)

        let clock = self.clock
        let api = FakeAPI(["POST /v1/token/refresh": { _ in .data(tokens(sessionId: "old-but-kept", nowMs: clock.time)) }])
        let second = await start(api, foreground: true)

        XCTAssertEqual(api.calls.count, 1)
        XCTAssertGreaterThan(second.currentSession?.expiresAt ?? 0, clock.time)
    }
}
