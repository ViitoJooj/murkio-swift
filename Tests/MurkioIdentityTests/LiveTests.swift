import Foundation
import XCTest
@testable import MurkioIdentity

/// Runs against a real identity API, through the transport the SDK ships
/// with, when these are set: MURKIO_LIVE_API, MURKIO_LIVE_PK,
/// MURKIO_LIVE_EMAIL, MURKIO_LIVE_PASSWORD (an application with a verified
/// user). Skipped otherwise.
final class LiveTests: XCTestCase {
    @MainActor
    func testBootstrapLoginProfileRefreshAndLogoutAgainstTheAPI() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiURL = environment["MURKIO_LIVE_API"], let key = environment["MURKIO_LIVE_PK"],
              let email = environment["MURKIO_LIVE_EMAIL"], let password = environment["MURKIO_LIVE_PASSWORD"],
              ![apiURL, key, email, password].contains("")
        else { throw XCTSkip("set MURKIO_LIVE_* to run against a real API") }

        let storage = MurkioMemoryStorage()
        func create(aheadMs: Int64 = 0) throws -> MurkioClient {
            try MurkioClient(
                publishableKey: key, apiURL: apiURL, locale: "en", storage: storage, transport: URLSessionTransport(),
                now: { Int64(Date().timeIntervalSince1970 * 1000) + aheadMs }, isForeground: { false }
            )
        }

        let client = try create()
        await client.start()
        let bootstrap = try await client.bootstrap()
        XCTAssertFalse(bootstrap.applicationId.isEmpty)
        XCTAssertFalse(pickCanvas(bootstrap.canvasDocument, config: bootstrap.config).signIn.elements.isEmpty)

        let flow = FlowController(client: client)
        await flow.login(MurkioCredentials(email: email, password: "definitely-wrong", keepLogged: true))
        XCTAssertEqual(flow.state.error?.code, "rsb-00")

        await flow.login(MurkioCredentials(email: "  \(email.uppercased()) ", password: password, keepLogged: true))
        XCTAssertNil(flow.state.error)
        XCTAssertEqual(flow.state.step, .done)
        let first = try XCTUnwrap(client.currentSession)
        XCTAssertEqual(first.claims?.sessionId, first.sessionId)

        let user = try await client.getUser()
        XCTAssertEqual(user?.email, email)
        XCTAssertEqual(user?.sessionId, first.sessionId)

        // A second client on the same storage is "the next run of the app",
        // with a clock far enough ahead to make the token due.
        let later = try create(aheadMs: 20 * 60_000)
        await later.start()
        async let one = later.getToken()
        async let two = later.getToken()
        let tokens = try await [one, two]
        XCTAssertNotNil(tokens[0])
        XCTAssertEqual(tokens[0], tokens[1])
        XCTAssertNotEqual(tokens[0], first.accessToken)
        XCTAssertEqual(later.currentSession?.sessionId, first.sessionId)
        let again = try await later.getUser()
        XCTAssertEqual(again?.id, user?.id)

        let refreshToken = try XCTUnwrap(later.currentSession?.refreshToken)
        await later.signOut()
        XCTAssertFalse(later.isSignedIn)
        do {
            _ = try await later.api.refresh(refreshToken)
            XCTFail("the refresh token of a signed-out session must be refused")
        } catch let error as MurkioError {
            XCTAssertTrue(["rsb-02", "rsb-03", "rsb-05"].contains(error.code), error.code)
        }
    }
}
