#if canImport(SwiftUI) && canImport(Combine)
import SwiftUI
import XCTest
@testable import MurkioIdentity

#if canImport(Security)
final class KeychainTests: XCTestCase {
    func testTheKeychainRoundTripsAndForgets() throws {
        let storage = KeychainStorage(service: "com.murkio.identity.tests.\(UUID().uuidString)")
        storage.write("murkio.probe", "x")
        guard storage.read("murkio.probe") == "x" else {
            throw XCTSkip("this environment gives the test process no keychain")
        }
        storage.delete("murkio.probe")

        storage.write("murkio.test.session", "{\"refreshToken\":\"segredo\"}")
        XCTAssertEqual(storage.read("murkio.test.session"), "{\"refreshToken\":\"segredo\"}")
        storage.write("murkio.test.session", "second")
        XCTAssertEqual(storage.read("murkio.test.session"), "second", "a write replaces the item")

        storage.delete("murkio.test.session")
        XCTAssertNil(storage.read("murkio.test.session"))
        XCTAssertNil(storage.read("murkio.never.written"))
    }
}
#endif

@MainActor
final class CanvasModelTests: XCTestCase {
    private func canvasAPI(document: JSONValue? = nil, password: Bool = true, providers: [String] = []) -> FakeAPI {
        FakeAPI(["GET /v1/client": { _ in .data(bootstrapJSON(document: document, password: password, providers: providers)) }])
    }

    func testAPreviewLoadsTheDocumentWithoutAClient() async {
        let model = CanvasModel()
        await model.load(client: nil, preview: readSpec("canvas/default.json"))
        XCTAssertEqual(model.document, defaultCanvas())
        XCTAssertTrue(model.isPreview)
        XCTAssertNil(model.flow)

        model.act("login", screen: defaultCanvas().signIn)
        XCTAssertEqual(model.state, FlowState(), "the actions of a preview do nothing")
    }

    func testTheCanvasSignsInAndReportsIt() async {
        let api = canvasAPI().on("POST /v1/login") { _ in .data(tokens()) }
        let client = makeClient(api)
        let model = CanvasModel()
        var logins: [MurkioSession] = []
        model.onLogin = { logins.append($0) }
        await model.load(client: client, preview: nil)
        XCTAssertEqual(model.config?.passwordEnabled, true)

        model.email = "  Ana@Example.com "
        model.password = "S3nha!forte"
        model.act("login", screen: defaultCanvas().signIn)
        await eventually("the sign-in") { await MainActor.run { model.state.step == .done } }

        XCTAssertEqual(api.to("/v1/login").first?.body, ["email": "ana@example.com", "password": "S3nha!forte"])
        XCTAssertEqual(logins.map { $0.sessionId }, ["session-1"])
        XCTAssertEqual(model.password, "", "the password is dropped once it was used")
        XCTAssertEqual(client.currentSession?.ephemeral, true, "the default canvas has the box unchecked")
    }

    func testTheCheckboxAndItsAbsenceDecideIfTheSessionIsKept() async {
        let model = CanvasModel()
        await model.load(client: makeClient(canvasAPI()), preview: nil)
        let screen = defaultCanvas().signIn
        XCTAssertFalse(model.keepLogged(screen))
        model.keepLoggedChoice = true
        XCTAssertTrue(model.keepLogged(screen))

        let without = CanvasScreen(elements: screen.elements.filter { $0.type != .keepLogged }, desktop: screen.desktop, mobile: nil)
        model.keepLoggedChoice = nil
        XCTAssertTrue(model.keepLogged(without), "no checkbox on the screen: an app keeps its user signed in")
    }

    func testErrorsAndStepsAreReported() async {
        let api = canvasAPI()
            .on("POST /v1/login") { _ in .error(401, "rsb-00") }
            .on("POST /v1/signup") { _ in Answer(204) }
        let model = CanvasModel()
        var errors: [String] = []
        var steps: [String] = []
        model.onError = { errors.append($0.code) }
        model.onStep = { steps.append($0) }
        await model.load(client: makeClient(api), preview: nil)
        model.email = "ana@example.com"
        model.password = "errada"

        model.act("login", screen: defaultCanvas().signIn)
        await eventually("the error") { await MainActor.run { model.state.error != nil } }
        XCTAssertEqual(errors, ["rsb-00"])

        model.act("register", screen: defaultCanvas().signIn)
        await eventually("the email code screen") { await MainActor.run { model.state.step.name == "verify_email" } }
        XCTAssertEqual(steps, ["verify_email"])
    }

    func testWithoutTheAPITheDefaultCanvasShowsWithAnError() async {
        let model = CanvasModel()
        await model.load(client: makeClient(FakeAPI(["GET /v1/client": { _ in throw Offline() }])), preview: nil)
        XCTAssertEqual(model.document, defaultCanvas())
        XCTAssertTrue(model.failed)
    }

    func testAStandaloneFormSignsInAndKeepsTheSessionWithoutACheckbox() async {
        let api = canvasAPI().on("POST /v1/login") { _ in .data(tokens()) }
        let client = makeClient(api)
        let form = MurkioForm(client: client)
        var logins = 0
        form.onLogin = { _ in logins += 1 }
        form.email = " Ana@Example.com"
        form.password = "S3nha!forte"

        await form.login()

        XCTAssertEqual(api.to("/v1/login").first?.body, ["email": "ana@example.com", "password": "S3nha!forte"])
        XCTAssertEqual(form.state.step, .done)
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(form.password, "")
        XCTAssertEqual(client.currentSession?.ephemeral, false)
        XCTAssertNil(form.presenter, "a flow the app started is presented by murkioSteps")

        form.keepLoggedControls = 1
        XCTAssertFalse(form.keepLogged, "with the toggle on screen, off means off")
    }

    func testAStandaloneSignupLoadsTheThemeForItsScreens() async {
        let api = canvasAPI().on("POST /v1/signup") { _ in Answer(204) }
        let form = MurkioForm(client: makeClient(api))
        form.email = "ana@example.com"
        form.password = "S3nha!forte"
        let presenter = UUID()

        await form.run(register: true, presenter: presenter)

        XCTAssertEqual(form.state.step.name, "verify_email")
        XCTAssertEqual(form.presenter, presenter)
        await eventually("the canvas theme") { await MainActor.run { form.theme != nil } }
        XCTAssertEqual(form.theme, defaultCanvas().theme)
        form.back()
        XCTAssertEqual(form.state.step, .signIn)
    }

    func testTheSessionObjectFollowsSignInsAndSignOuts() async {
        let client = makeClient(FakeAPI(["POST /v1/logout": { _ in Answer(204) }]))
        let auth = MurkioAuth(client: client)
        XCTAssertFalse(auth.isSignedIn)

        await client.sessions.setSession(tokenPair(), keepLogged: true)
        await eventually("the sign-in") { await MainActor.run { auth.isSignedIn } }
        await auth.signOut()
        await eventually("the sign-out") { await MainActor.run { !auth.isSignedIn } }
    }
}

#if canImport(AppKit)
import AppKit

/// The canvas in a real SwiftUI layout pass (an offscreen window), checked
/// against the same boxes the web SDK is checked against.
@MainActor
final class CanvasViewTests: XCTestCase {
    private func host<V: View>(_ view: V, width: Double, height: Double = 2600) -> (NSHostingView<AnyView>, NSWindow) {
        let root = AnyView(view.frame(width: CGFloat(width), alignment: .top).frame(maxHeight: .infinity, alignment: .top))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        // A test process has no application object until one is asked for, and
        // a window made in code frees itself on close unless told otherwise
        // (the test holds it too, which would free it twice).
        _ = NSApplication.shared
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    /// True when SwiftUI placed exactly the expected elements, each within half a point of its box.
    private func matches(_ frames: [String: CGRect], _ expected: [String: JSONValue]) -> Bool {
        guard Set(frames.keys) == Set(expected.keys) else { return false }
        return expected.allSatisfy { id, want in
            guard let frame = frames[id] else { return false }
            return abs(Double(frame.minX) - (want["x"]?.number ?? -1)) <= 0.5 && abs(Double(frame.minY) - (want["y"]?.number ?? -1)) <= 0.5
                && abs(Double(frame.width) - (want["w"]?.number ?? -1)) <= 0.5 && abs(Double(frame.height) - (want["h"]?.number ?? -1)) <= 0.5
        }
    }

    func testEveryElementIsDrawnWhereTheWebDrawsIt() async throws {
        let layouts = vectors["layout"]?.array ?? []
        XCTAssertGreaterThanOrEqual(layouts.count, 20)
        var checked = 0

        for (index, entry) in layouts.enumerated() {
            let reference = entry["document"]?.string ?? ""
            let width = entry["width"]?.number ?? 0
            let expected = entry["expect"]?["items"]?.object ?? [:]
            let at = "layout #\(index) (\(reference) at \(width))"
            let screen: MurkioScreen = entry["screen"]?.string == "sign_up" ? .signUp : .signIn

            let frames = Frames()
            var canvas: MurkioIdentityCanvas
            if let settings = entry["config"], !settings.isNull {
                let raw = rawDocument(at: reference)
                let api = FakeAPI([
                    "GET /v1/client": { _ in
                        guard case .object(var bootstrap) = bootstrapJSON(document: raw) else { return Answer(500) }
                        bootstrap["config"] = settings
                        return .data(.object(bootstrap))
                    }
                ])
                let client = makeClient(api, oauthRedirectURL: entry["oauth"]?.bool == true ? "https://app.example.com/callback" : nil)
                canvas = MurkioIdentityCanvas(client: client, screen: screen)
            } else {
                canvas = MurkioIdentityCanvas(screen: screen, locale: "en", preview: rawDocument(at: reference).write())
            }
            canvas.onLayout = { frames.value = $0 }

            let (hosting, window) = host(canvas, width: width)
            defer { window.close() }
            // The first pass runs before the canvas knows its width or has loaded; wait for the settled layout.
            for _ in 0..<300 where !matches(frames.value, expected) {
                try await Task.sleep(nanoseconds: 10_000_000)
                hosting.layoutSubtreeIfNeeded()
            }
            guard !frames.value.isEmpty else {
                throw XCTSkip("SwiftUI reported no layout: this environment has no window server")
            }

            XCTAssertEqual(Set(frames.value.keys), Set(expected.keys), at)
            for (id, want) in expected {
                guard let frame = frames.value[id] else { continue }
                XCTAssertEqual(Double(frame.minX), want["x"]?.number ?? -1, accuracy: 0.5, "\(at) \(id).x")
                XCTAssertEqual(Double(frame.minY), want["y"]?.number ?? -1, accuracy: 0.5, "\(at) \(id).y")
                XCTAssertEqual(Double(frame.width), want["w"]?.number ?? -1, accuracy: 0.5, "\(at) \(id).w")
                XCTAssertEqual(Double(frame.height), want["h"]?.number ?? -1, accuracy: 0.5, "\(at) \(id).h")
            }
            checked += 1
        }
        XCTAssertEqual(checked, layouts.count)
    }

    /// Writes PNGs of the canvas to MURKIO_SCREENSHOTS, to look at what SwiftUI really paints.
    func testRendersTheDefaultCanvasToAnImage() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MURKIO_SCREENSHOTS"], !directory.isEmpty else {
            throw XCTSkip("set MURKIO_SCREENSHOTS=<dir> to render")
        }
        let frames = Frames()
        var canvas = MurkioIdentityCanvas(locale: "en", preview: readSpec("canvas/default.json").write())
        canvas.onLayout = { frames.value = $0 }
        let (hosting, window) = host(canvas.background(Color(white: 0.95)), width: 420, height: 560)
        defer { window.close() }
        for _ in 0..<300 where frames.value.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            hosting.layoutSubtreeIfNeeded()
        }
        guard !frames.value.isEmpty else { throw XCTSkip("no window server") }

        let area = hosting.bounds
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: area) else { throw XCTSkip("cannot capture") }
        hosting.cacheDisplay(in: area, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("swift-canvas.png"))
        XCTAssertGreaterThan(png.count, 1000)
    }
}

@MainActor
private final class Frames {
    var value: [String: CGRect] = [:]
}
#endif
#endif
