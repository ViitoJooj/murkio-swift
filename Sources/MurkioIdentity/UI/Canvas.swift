#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Which screen of the canvas to draw.
public enum MurkioScreen: Sendable {
    case signIn
    case signUp
}

/// What the canvas knows and what the user typed. It outlives redraws of the view.
@MainActor
final class CanvasModel: ObservableObject {
    @Published private(set) var document: CanvasDocument?
    @Published private(set) var config: PublicConfig?
    @Published private(set) var failed = false
    @Published private(set) var state = FlowState()
    @Published var email = ""
    @Published var password = ""
    @Published var keepLoggedChoice: Bool?
    @Published var obscure = true
    /// Bumped when the keyboard's "next" on the email field should move to the password.
    @Published var focusPassword = 0

    private(set) var client: MurkioClient?
    private(set) var flow: FlowController?
    private var observation: MurkioObservation?
    var onLogin: ((MurkioSession) -> Void)?
    var onError: ((MurkioError) -> Void)?
    var onStep: ((String) -> Void)?

    var isPreview: Bool { client == nil }

    /// Loads the canvas: the given document in a preview, else the published one of the client.
    func load(client: MurkioClient?, preview: JSONValue?) async {
        observation?.cancel()
        observation = nil
        flow = nil
        state = FlowState()
        self.client = client

        guard let client else {
            config = nil
            failed = false
            document = pickCanvas(preview, config: nil, onProblems: CanvasModel.warn)
            return
        }

        await client.start()
        do {
            let bootstrap = try await client.bootstrap()
            config = bootstrap.config
            failed = false
            document = pickCanvas(bootstrap.canvasDocument, config: bootstrap.config, onProblems: CanvasModel.warn)
        } catch {
            config = nil
            failed = true
            document = defaultCanvas()
        }

        let flow = FlowController(client: client)
        self.flow = flow
        state = flow.state
        observation = flow.observe { [weak self] next in self?.changed(to: next) }
        await flow.takeOAuthReturn()
    }

    private nonisolated static func warn(_ problems: [String]) {
        print("[murkio] the canvas has problems; affected elements were skipped: \(problems.joined(separator: "; "))")
    }

    private func changed(to next: FlowState) {
        let previous = state
        state = next
        if let error = next.error, error != previous.error { onError?(error) }
        guard next.step.name != previous.step.name else { return }
        if next.inStep { onStep?(next.step.name) }
        if next.step == .done {
            // The password is dropped once it was used.
            password = ""
            if let session = client?.currentSession { onLogin?(session) }
        }
    }

    func keepLogged(_ screen: CanvasScreen) -> Bool {
        keepLoggedChoice ?? keepLoggedDefault(screen, config: isPreview ? nil : config)
    }

    func act(_ action: String, screen: CanvasScreen, provider: String? = nil) {
        guard let flow else { return }
        let credentials = MurkioCredentials(email: email, password: password, keepLogged: keepLogged(screen))
        switch action {
        case "login": Task { await flow.login(credentials) }
        case "register": Task { await flow.register(credentials) }
        case "forgot": flow.forgot(email: email)
        case "oauth": Task { await flow.oauth(provider: provider ?? "", keepLogged: credentials.keepLogged) }
        default: break
        }
    }
}

/// Draws the application's published login canvas and runs the whole sign-in
/// on it: signup, email code, two-step verification, password reset and
/// social sign-in.
///
/// ```swift
/// MurkioIdentityCanvas(onLogin: { session in showHome() })
/// ```
///
/// The canvas takes the width it is given and is as tall as its layout; put
/// it in a `ScrollView` so the keyboard never covers it.
@MainActor
public struct MurkioIdentityCanvas: View {
    private let client: MurkioClient?
    private let screen: MurkioScreen
    private let locale: String?
    private let preview: String?
    private let onLogin: ((MurkioSession) -> Void)?
    private let onError: ((MurkioError) -> Void)?
    private let onStep: ((String) -> Void)?
    private let onLink: ((String) -> Void)?
    var onLayout: (([String: CGRect]) -> Void)?

    @StateObject private var model = CanvasModel()
    @State private var width: CGFloat = 0

    /// - Parameters:
    ///   - client: the client to use. Defaults to the app's one (`Murkio.client`).
    ///   - locale: language of the texts. Defaults to the client's option, then the device's.
    ///   - preview: a canvas document (JSON) to draw without the API: every element shows and
    ///     the actions do nothing. For editors and screenshots.
    ///   - onLogin: the user is signed in.
    ///   - onError: an action failed. The canvas already shows the translated message.
    ///   - onStep: a built-in screen opened (`verify_email`, `mfa`, `mfa_enroll`,
    ///     `recovery_codes`, `forgot`, `reset`).
    ///   - onLink: a link of the canvas was tapped. Without it an https link opens in the
    ///     browser and a site path (`/terms`) does nothing: an app has no site to resolve it against.
    public init(
        client: MurkioClient? = nil,
        screen: MurkioScreen = .signIn,
        locale: String? = nil,
        preview: String? = nil,
        onLogin: ((MurkioSession) -> Void)? = nil,
        onError: ((MurkioError) -> Void)? = nil,
        onStep: ((String) -> Void)? = nil,
        onLink: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.screen = screen
        self.locale = locale
        self.preview = preview
        self.onLogin = onLogin
        self.onError = onError
        self.onStep = onStep
        self.onLink = onLink
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .top)
            .background(GeometryReader { proxy in Color.clear.preference(key: WidthKey.self, value: proxy.size.width) })
            .onPreferenceChange(WidthKey.self) { width = $0 }
            .onPreferenceChange(ElementFramesKey.self) { frames in onLayout?(frames) }
            .task(id: preview) {
                model.onLogin = onLogin
                model.onError = onError
                model.onStep = onStep
                // The client is resolved here, on the main actor: a missing setup stops with the message that says what to add.
                await model.load(client: preview == nil ? (client ?? Murkio.client) : nil, preview: preview.flatMap(JSONValue.parse))
            }
    }

    private var language: String {
        normalizeLocale(locale ?? model.client?.configuredLocale ?? deviceLocale())
    }

    @ViewBuilder
    private var content: some View {
        if let document = model.document {
            if let flow = model.flow, model.state.inStep {
                StepView(flow: flow, state: model.state, theme: document.theme, locale: language) { link in
                    model.client?.openURL(link)
                }
                .id(model.state.step.name)
            } else {
                canvasFrame(document)
            }
        }
    }

    private func open(_ href: String) {
        if let onLink {
            onLink(href)
        } else if !href.hasPrefix("/") {
            model.client?.openURL(href)
        }
    }

    @ViewBuilder
    private func canvasFrame(_ document: CanvasDocument) -> some View {
        let signUp = screen == .signUp && document.signUp != nil
        let canvasScreen = signUp ? (document.signUp ?? document.signIn) : document.signIn
        let config = model.isPreview ? nil : model.config
        let oauth = model.isPreview || (model.client?.oauthEnabled ?? false)
        let available = width > 0 ? Double(width) : Double(canvasScreen.desktop.width)
        let placement = place(canvasScreen, width: available, config: config, oauth: oauth)
        let submit = submitAction(canvasScreen, signUp: signUp, config: config, oauth: oauth)
        let slot = placement.order.first { $0.type == .errorMessage }?.id
        let message = self.message
        let reading = Dictionary(uniqueKeysWithValues: placement.order.enumerated().map { ($0.element.id, $0.offset) })

        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                ForEach(placement.paint) { element in
                    let rect = placement.rects[element.id] ?? CanvasRect(x: 0, y: 0, w: 0, h: 0)
                    ElementView(
                        element: element, screen: canvasScreen, theme: document.theme, locale: language, signUp: signUp,
                        submit: submit, message: element.id == slot ? message : nil, model: model, onLink: { href in open(href) }
                    )
                    .frame(width: CGFloat(rect.w), height: CGFloat(rect.h), alignment: .topLeading)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ElementFramesKey.self, value: [element.id: proxy.frame(in: .named("murkio-frame"))])
                    })
                    .offset(x: CGFloat(rect.x), y: CGFloat(rect.y))
                    .allowsHitTesting(!element.type.decorative)
                    .accessibilitySortPriority(Double(placement.order.count - (reading[element.id] ?? 0)))
                }
            }
            .frame(width: CGFloat(placement.frameWidth), height: CGFloat(placement.frameHeight), alignment: .topLeading)
            .background(placement.background.map { Color($0) } ?? Color.clear)
            .coordinateSpace(name: "murkio-frame")

            if slot == nil, let message {
                Text(message.text)
                    .font(themeFont(document.theme, size: 14, weight: .regular))
                    .foregroundColor(Color(message.isNotice ? document.theme.text : document.theme.error))
                    .frame(width: CGFloat(placement.frameWidth), alignment: .leading)
            }
        }
    }

    /// The error or notice to show on the canvas, if any.
    private var message: CanvasMessage? {
        if let error = model.state.error { return CanvasMessage(text: translateError(error.code, language), isNotice: false) }
        if let notice = model.state.notice { return CanvasMessage(text: murkioString(language, notice), isNotice: true) }
        if model.failed { return CanvasMessage(text: translateError("unknown", language), isNotice: false) }
        return nil
    }
}

struct CanvasMessage: Equatable {
    let text: String
    let isNotice: Bool
}

/// One element of the canvas, filling the frame it is given.
@MainActor
private struct ElementView: View {
    let element: CanvasElement
    let screen: CanvasScreen
    let theme: CanvasTheme
    let locale: String
    let signUp: Bool
    let submit: String
    let message: CanvasMessage?
    @ObservedObject var model: CanvasModel
    let onLink: (String) -> Void

    private enum Field {
        case email, password
    }

    @FocusState private var focus: Field?

    var body: some View {
        let look = resolveLook(element, theme: theme)
        switch element.type {
        case .emailInput:
            let label = element.label?.pick(locale) ?? ""
            let hint = element.placeholder?.pick(locale) ?? ""
            MurkioTextField(
                text: $model.email, look: look, theme: theme, label: label, hint: hint.isEmpty ? label : hint, kind: .email,
                submitLabel: .next, onSubmit: { model.focusPassword += 1 }
            )
            .elementBox(look)
        case .passwordInput:
            let label = element.label?.pick(locale) ?? ""
            let hint = element.placeholder?.pick(locale) ?? ""
            HStack(spacing: 0) {
                MurkioTextField(
                    text: $model.password, look: look, theme: theme, label: label, hint: hint.isEmpty ? label : hint,
                    kind: signUp ? .newPassword : .password, obscure: model.obscure,
                    onSubmit: { model.act(submit, screen: screen) }
                )
                .focused($focus, equals: .password)
                .onChange(of: model.focusPassword) { _ in focus = .password }
                if element.showToggle {
                    Button(action: { model.obscure.toggle() }) {
                        Image(systemName: model.obscure ? "eye" : "eye.slash")
                            .foregroundColor(Color(theme.muted))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(murkioString(locale, model.obscure ? "password.show" : "password.hide"))
                }
            }
            .elementBox(look)
        case .keepLogged:
            let checked = model.keepLogged(screen)
            Button(action: { model.keepLoggedChoice = !checked }) {
                HStack(spacing: 8) {
                    CheckBox(checked: checked, accent: Color(theme.primary), onAccent: Color(theme.onPrimary), outline: Color(theme.border))
                    Text(element.label?.pick(locale) ?? "")
                        .font(look.font(theme))
                        .foregroundColor(Color(look.foreground))
                        .frame(maxWidth: .infinity, alignment: look.alignment(top: false))
                }
                .elementBox(look)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checked ? .isSelected : [])
        case .loginButton, .registerButton:
            MurkioButton(label: element.label?.pick(locale) ?? "", look: look, theme: theme, busy: model.state.busy) {
                model.act(element.type == .loginButton ? "login" : "register", screen: screen)
            }
        case .oauthButton:
            let provider = element.provider ?? ""
            let label = element.label?.pick(locale) ?? ""
            MurkioButton(
                label: label.isEmpty ? murkioString(locale, "oauth.continue", ["provider": providerName(provider)]) : label,
                look: look, theme: theme, busy: model.state.busy
            ) {
                model.act("oauth", screen: screen, provider: provider)
            }
        case .forgotPasswordLink:
            MurkioButton(label: element.label?.pick(locale) ?? "", look: look, theme: theme, busy: model.state.busy, underline: true) {
                model.act("forgot", screen: screen)
            }
        case .link:
            MurkioButton(label: element.text?.pick(locale) ?? "", look: look, theme: theme, underline: true, top: true) {
                onLink(element.href ?? "")
            }
        case .errorMessage:
            // Text starts at the top of its box and, like on the web, is not cut
            // when a font makes it a little taller than the box the editor drew.
            Text(message?.text ?? "")
                .font(look.font(theme))
                .foregroundColor(Color(message?.isNotice == true ? theme.text : look.foreground))
                .multilineTextAlignment(look.textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: look.alignment(top: true))
                .elementBox(look)
        case .text:
            Text(element.text?.pick(locale) ?? "")
                .font(look.font(theme))
                .foregroundColor(Color(look.foreground))
                .multilineTextAlignment(look.textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: look.alignment(top: true))
                .elementBox(look)
                .accessibilityAddTraits(element.isHeading ? .isHeader : [])
        case .image:
            CanvasImage(source: element.src ?? "", description: element.alt?.pick(locale) ?? "")
                .elementBox(look)
        case .shape:
            Color.clear
                .elementBox(look)
                .accessibilityHidden(true)
        case .divider:
            let label = element.label?.pick(locale) ?? ""
            HStack(spacing: 12) {
                Rectangle().fill(Color(theme.border)).frame(height: 1)
                if !label.isEmpty {
                    Text(label).font(look.font(theme)).foregroundColor(Color(look.foreground)).fixedSize()
                    Rectangle().fill(Color(theme.border)).frame(height: 1)
                }
            }
            .elementBox(look)
        }
    }
}

/// The image of a canvas element (`https:` or `data:`), fitted inside its
/// box. If it cannot be loaded the box stays empty.
@MainActor
private struct CanvasImage: View {
    let source: String
    let description: String

    var body: some View {
        Group {
            if source.hasPrefix("data:") {
                if let image = decoded {
                    image.resizable().scaledToFit()
                }
            } else if let url = URL(string: source) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .accessibilityLabel(description)
        .accessibilityHidden(description.isEmpty)
    }

    private var decoded: Image? {
        guard let comma = source.firstIndex(of: ","), let bytes = base64Decode(String(source[source.index(after: comma)...])) else {
            return nil
        }
        let data = Data(bytes)
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}
#endif
