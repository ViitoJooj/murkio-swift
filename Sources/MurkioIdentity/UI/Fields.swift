#if canImport(SwiftUI)
import SwiftUI

/// MurkioForm joins the standalone views of one form: the inputs write the
/// values, the buttons run the flow with them, and the built-in screens (email
/// code, two-step verification, password reset) open in a sheet painted with
/// the application's canvas theme.
///
/// Views outside a `MurkioIdentityForm` share the default form of the client,
/// so most apps never create one. Its fields are published, so your own
/// controls can use them too: `TextField("Email", text: $form.email)`.
@MainActor
public final class MurkioForm: ObservableObject {
    @Published public var email = ""
    @Published public var password = ""
    @Published public private(set) var state = FlowState()
    @Published var keepLoggedValue = false
    @Published var keepLoggedControls = 0
    /// The button that started the flow in course: it is the one that presents the built-in screens.
    @Published var presenter: UUID?
    @Published private(set) var theme: CanvasTheme?

    public let client: MurkioClient
    let flow: FlowController
    private var observation: MurkioObservation?

    /// Called when the user is signed in.
    public var onLogin: ((MurkioSession) -> Void)?
    /// Called when an action fails.
    public var onError: ((MurkioError) -> Void)?

    public init(client: MurkioClient? = nil) {
        let resolved = client ?? Murkio.client
        self.client = resolved
        flow = FlowController(client: resolved)
        observation = flow.observe { [weak self] next in self?.changed(to: next) }
    }

    private static var defaults: [ObjectIdentifier: MurkioForm] = [:]

    /// The form shared by every view that is not inside a `MurkioIdentityForm`.
    public static func shared(for client: MurkioClient? = nil) -> MurkioForm {
        let resolved = client ?? Murkio.client
        if let existing = defaults[ObjectIdentifier(resolved)] { return existing }
        let created = MurkioForm(client: resolved)
        defaults[ObjectIdentifier(resolved)] = created
        return created
    }

    /// "Keep me signed in". Without a `MurkioIdentityKeepLogged` in the form
    /// the session is kept: that is what a user expects from an app.
    public var keepLogged: Bool {
        get { keepLoggedControls == 0 ? true : keepLoggedValue }
        set { keepLoggedValue = newValue }
    }

    /// Signs in with what the inputs hold.
    public func login() async {
        await run(register: false, presenter: nil)
    }

    /// Creates the account with what the inputs hold.
    public func register() async {
        await run(register: true, presenter: nil)
    }

    /// Runs the form. `presenter` is the view that shows the built-in screens
    /// of this attempt: one of the SDK's controls, or nil for the app's own
    /// (`murkioSteps`). Exactly one sheet answers, whoever started it.
    func run(register: Bool, presenter: UUID?) async {
        self.presenter = presenter
        let credentials = MurkioCredentials(email: email, password: password, keepLogged: keepLogged)
        if register {
            await flow.register(credentials)
        } else {
            await flow.login(credentials)
        }
    }

    /// Leaves a built-in screen and goes back to the form.
    public func back() {
        flow.back()
    }

    private func changed(to next: FlowState) {
        let previous = state
        state = next
        if let error = next.error, error != previous.error { onError?(error) }
        if next.inStep, theme == nil { Task { await loadTheme() } }
        guard next.step.name != previous.step.name, next.step == .done else { return }
        password = ""
        if let session = client.currentSession { onLogin?(session) }
    }

    private func loadTheme() async {
        if let bootstrap = try? await client.bootstrap() {
            theme = pickCanvas(bootstrap.canvasDocument, config: bootstrap.config).theme
        } else {
            theme = defaultCanvas().theme
        }
    }
}

private struct MurkioFormKey: EnvironmentKey {
    static let defaultValue: MurkioForm? = nil
}

extension EnvironmentValues {
    var murkioForm: MurkioForm? {
        get { self[MurkioFormKey.self] }
        set { self[MurkioFormKey.self] = newValue }
    }
}

/// Gives the views inside it their own form, apart from the app's default
/// one. Only needed for two independent forms on screen, to use a client other
/// than the app's, or to receive `onLogin` and `onError` in one place.
@MainActor
public struct MurkioIdentityForm<Content: View>: View {
    @StateObject private var form: MurkioForm
    private let onLogin: ((MurkioSession) -> Void)?
    private let onError: ((MurkioError) -> Void)?
    private let content: (MurkioForm) -> Content

    public init(
        client: MurkioClient? = nil,
        onLogin: ((MurkioSession) -> Void)? = nil,
        onError: ((MurkioError) -> Void)? = nil,
        @ViewBuilder content: @escaping (MurkioForm) -> Content
    ) {
        _form = StateObject(wrappedValue: MurkioForm(client: client))
        self.onLogin = onLogin
        self.onError = onError
        self.content = content
    }

    public var body: some View {
        content(form)
            .environment(\.murkioForm, form)
            .onAppear {
                form.onLogin = onLogin
                form.onError = onError
            }
    }
}

/// Resolves the form of a standalone view and hands it to `content` as an observed object.
@MainActor
private struct WithForm<Content: View>: View {
    @Environment(\.murkioForm) private var scoped
    let content: (MurkioForm) -> Content

    init(@ViewBuilder content: @escaping (MurkioForm) -> Content) {
        self.content = content
    }

    var body: some View {
        Observing(form: scoped ?? MurkioForm.shared(), content: content)
    }

    private struct Observing: View {
        @ObservedObject var form: MurkioForm
        let content: (MurkioForm) -> Content

        var body: some View {
            content(form)
        }
    }
}

/// The built-in screens of a form, in a sheet. Attached by the SDK's buttons;
/// use `murkioSteps(_:)` yourself when your own button calls `form.login()`.
@MainActor
private struct StepSheet: ViewModifier {
    @ObservedObject var form: MurkioForm
    /// The control this sheet belongs to; nil for the app's own button (`murkioSteps`).
    let presenter: UUID?

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { form.state.inStep && form.presenter == presenter },
            set: { shown in if !shown, form.state.inStep { form.back() } }
        )) {
            ScrollView {
                if let theme = form.theme {
                    StepView(flow: form.flow, state: form.state, theme: theme, locale: form.client.locale) { link in
                        form.client.openURL(link)
                    }
                    .id(form.state.step.name)
                }
            }
            .background(form.theme.map { Color($0.background) } ?? Color.clear)
        }
    }
}

extension View {
    /// Shows the built-in screens of `form` (email code, two-step verification,
    /// password reset) in a sheet over this view. The SDK's own buttons already
    /// do it; this is for a button of yours that calls `form.login()`.
    @MainActor
    public func murkioSteps(_ form: MurkioForm) -> some View {
        modifier(StepSheet(form: form, presenter: nil))
    }
}

/// The email field of a sign-in form. It is a regular SwiftUI `TextField`:
/// style it with the usual modifiers (`.textFieldStyle`, `.font`, `.padding`…).
@MainActor
public struct MurkioIdentityEmailInput: View {
    private let title: String

    public init(_ title: String = "Email") {
        self.title = title
    }

    public var body: some View {
        WithForm { form in
            TextField(title, text: Binding(get: { form.email }, set: { form.email = $0 }))
                .fieldTraits(.email)
        }
    }
}

/// The password field of a sign-in form. The keyboard's action button signs
/// in (or registers, with `newPassword`).
@MainActor
public struct MurkioIdentityPasswordInput: View {
    private let title: String
    private let newPassword: Bool
    @State private var id = UUID()

    /// - Parameter newPassword: true on a sign-up form: password managers then offer a new
    ///   password, and the keyboard's action button registers instead of signing in.
    public init(_ title: String = "Password", newPassword: Bool = false) {
        self.title = title
        self.newPassword = newPassword
    }

    public var body: some View {
        WithForm { form in
            SecureField(title, text: Binding(get: { form.password }, set: { form.password = $0 }))
                .fieldTraits(newPassword ? .newPassword : .password)
                .onSubmit {
                    Task { await form.run(register: newPassword, presenter: id) }
                }
                .modifier(StepSheet(form: form, presenter: id))
        }
    }
}

/// The "keep me signed in" choice, as a `Toggle`: style it with
/// `.toggleStyle`. Off, the session ends when the app is closed.
@MainActor
public struct MurkioIdentityKeepLogged: View {
    private let title: String
    private let initialValue: Bool

    public init(_ title: String = "Keep me signed in", initialValue: Bool = false) {
        self.title = title
        self.initialValue = initialValue
    }

    public var body: some View {
        WithForm { form in
            Toggle(title, isOn: Binding(get: { form.keepLogged }, set: { form.keepLogged = $0 }))
                .onAppear {
                    if form.keepLoggedControls == 0 { form.keepLoggedValue = initialValue }
                    form.keepLoggedControls += 1
                }
                .onDisappear { form.keepLoggedControls -= 1 }
        }
    }
}

@MainActor
private struct ActionButton<Label: View>: View {
    let register: Bool
    let onLogin: ((MurkioSession) -> Void)?
    let onError: ((MurkioError) -> Void)?
    let label: () -> Label
    @State private var id = UUID()

    init(register: Bool, onLogin: ((MurkioSession) -> Void)?, onError: ((MurkioError) -> Void)?, label: @escaping () -> Label) {
        self.register = register
        self.onLogin = onLogin
        self.onError = onError
        self.label = label
    }

    var body: some View {
        WithForm { form in
            Button(action: {
                if let onLogin { form.onLogin = onLogin }
                if let onError { form.onError = onError }
                Task { await form.run(register: register, presenter: id) }
            }, label: label)
                .disabled(form.state.busy)
                .modifier(StepSheet(form: form, presenter: id))
        }
    }
}

/// Signs in with the email and password of its form. It is a regular SwiftUI
/// `Button`: style it with `.buttonStyle` and friends. It is disabled while a
/// request runs.
@MainActor
public struct MurkioIdentityLoginButton<Label: View>: View {
    private let onLogin: ((MurkioSession) -> Void)?
    private let onError: ((MurkioError) -> Void)?
    private let label: () -> Label

    public init(
        onLogin: ((MurkioSession) -> Void)? = nil,
        onError: ((MurkioError) -> Void)? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.onLogin = onLogin
        self.onError = onError
        self.label = label
    }

    public var body: some View {
        ActionButton(register: false, onLogin: onLogin, onError: onError, label: label)
    }
}

extension MurkioIdentityLoginButton where Label == Text {
    public init(_ title: String = "Sign in", onLogin: ((MurkioSession) -> Void)? = nil, onError: ((MurkioError) -> Void)? = nil) {
        self.init(onLogin: onLogin, onError: onError) { Text(title) }
    }
}

/// Creates the account with the email and password of its form, then asks for
/// the code sent to the email.
@MainActor
public struct MurkioIdentityRegisterButton<Label: View>: View {
    private let onLogin: ((MurkioSession) -> Void)?
    private let onError: ((MurkioError) -> Void)?
    private let label: () -> Label

    public init(
        onLogin: ((MurkioSession) -> Void)? = nil,
        onError: ((MurkioError) -> Void)? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.onLogin = onLogin
        self.onError = onError
        self.label = label
    }

    public var body: some View {
        ActionButton(register: true, onLogin: onLogin, onError: onError, label: label)
    }
}

extension MurkioIdentityRegisterButton where Label == Text {
    public init(_ title: String = "Create account", onLogin: ((MurkioSession) -> Void)? = nil, onError: ((MurkioError) -> Void)? = nil) {
        self.init(onLogin: onLogin, onError: onError) { Text(title) }
    }
}

/// Shows the translated error (or notice) of its form. Draws nothing when
/// there is nothing to say.
@MainActor
public struct MurkioIdentityError: View {
    private let locale: String?

    public init(locale: String? = nil) {
        self.locale = locale
    }

    public var body: some View {
        WithForm { form in
            let language = normalizeLocale(locale ?? form.client.locale)
            if form.state.inStep {
                EmptyView()
            } else if let error = form.state.error {
                Text(translateError(error.code, language)).foregroundColor(.red)
            } else if let notice = form.state.notice {
                Text(murkioString(language, notice))
            }
        }
    }
}

/// The signed-in session as an observable object: the view redraws when the
/// user signs in or out.
///
/// ```swift
/// @StateObject private var auth = MurkioAuth()
///
/// var body: some View {
///     if auth.session == nil { MurkioIdentityCanvas() } else { HomeView() }
/// }
/// ```
@MainActor
public final class MurkioAuth: ObservableObject {
    @Published public private(set) var session: MurkioSession?
    public let client: MurkioClient
    private var observation: MurkioObservation?

    public init(client: MurkioClient? = nil) {
        let resolved = client ?? Murkio.client
        self.client = resolved
        session = resolved.currentSession
        observation = resolved.observeSession { [weak self] next in
            Task { @MainActor in self?.session = next }
        }
        Task {
            await resolved.start()
            self.session = resolved.currentSession
        }
    }

    public var isSignedIn: Bool { session != nil }

    public func signOut() async {
        await client.signOut()
    }
}
#endif
