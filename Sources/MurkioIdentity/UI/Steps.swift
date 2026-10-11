#if canImport(SwiftUI)
import SwiftUI

/// Draws the built-in screen of a flow step (email code, two-step
/// verification, enrollment, recovery codes, password reset) with the canvas
/// theme. The customer only designs the sign-in (and sign-up) screen; these
/// follow its colors and font.
@MainActor
struct StepView: View {
    let flow: FlowController
    let state: FlowState
    let theme: CanvasTheme
    let locale: String
    let onOpenURL: (String) -> Void

    @State private var code = ""
    @State private var password = ""
    @State private var email = ""

    init(flow: FlowController, state: FlowState, theme: CanvasTheme, locale: String, onOpenURL: @escaping (String) -> Void) {
        self.flow = flow
        self.state = state
        self.theme = theme
        self.locale = locale
        self.onOpenURL = onOpenURL
    }

    private func say(_ key: String, _ params: [String: String] = [:]) -> String {
        murkioString(locale, key, params)
    }

    private var fieldLook: ElementLook {
        var look = ElementLook(foreground: theme.text)
        look.background = theme.surface
        look.borderColor = theme.border
        look.borderWidth = 1
        look.radius = Double(theme.radius)
        look.paddingX = 12
        look.paddingY = 10
        return look
    }

    private var buttonLook: ElementLook {
        var look = ElementLook(foreground: theme.onPrimary)
        look.background = theme.primary
        look.radius = Double(theme.radius)
        look.fontWeight = 600
        look.align = .center
        look.paddingX = 16
        return look
    }

    private var linkLook: ElementLook {
        var look = ElementLook(foreground: theme.primary)
        look.fontSize = 14
        look.align = .center
        return look
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            message
            controls
            if !isRecovery {
                link(say("back")) { flow.back() }
            }
        }
        .padding(24)
        .frame(maxWidth: 400, alignment: .leading)
        .background(Color(theme.background))
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear { if state.step == .forgot { email = flow.currentEmail } }
    }

    /// The recovery codes are the one screen without a way back: the session only starts after it.
    private var isRecovery: Bool {
        if case .recoveryCodes = state.step { return true }
        return false
    }

    private func heading(_ title: String, _ description: String, _ params: [String: String] = [:]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(say(title))
                .font(themeFont(theme, size: 22, weight: .bold))
                .foregroundColor(Color(theme.text))
                .accessibilityAddTraits(.isHeader)
            Text(say(description, params))
                .font(themeFont(theme, size: 16, weight: .regular))
                .foregroundColor(Color(theme.muted))
        }
    }

    private func field(_ text: Binding<String>, _ label: String, _ kind: FieldKind, onSubmit: @escaping () -> Void) -> some View {
        MurkioTextField(
            text: text, look: fieldLook, theme: theme, label: label, hint: label, kind: kind,
            obscure: kind == .password || kind == .newPassword, onSubmit: onSubmit
        )
        .frame(minHeight: 24)
        .elementBox(fieldLook, fill: false)
    }

    private func primary(_ label: String, _ action: @escaping () -> Void) -> some View {
        MurkioButton(label: label, look: buttonLook, theme: theme, busy: state.busy, action: action)
            .frame(height: 44)
    }

    private func link(_ label: String, _ action: @escaping () -> Void) -> some View {
        MurkioButton(label: label, look: linkLook, theme: theme, busy: state.busy, underline: true, action: action)
            .frame(height: 44)
    }

    private func run(_ task: @escaping () async -> Void) {
        Task { await task() }
    }

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case .verifyEmail(let address, let needsPassword):
            heading("verify.title", "verify.description", ["email": address])
            field($code, say("verify.code"), .code) { confirmEmail(needsPassword) }
            if needsPassword {
                field($password, say("verify.password"), .password) { confirmEmail(needsPassword) }
            }
        case .mfa:
            heading("mfa.title", "mfa.description")
            field($code, say("mfa.code"), .code) { run { await flow.verifyMfa(code: code) } }
        case .mfaEnroll(_, let secret, let otpauthUri):
            heading("enroll.title", "enroll.description")
            secretLine(secret)
            if otpauthUri.hasPrefix("otpauth://") {
                link(say("enroll.open")) { onOpenURL(otpauthUri) }
            }
            field($code, say("enroll.code"), .code) { run { await flow.confirmEnrollment(code: code) } }
        case .recoveryCodes(let codes):
            heading("recovery.title", "recovery.description")
            Text(codes.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                .font(.system(size: 15, design: .monospaced))
                .foregroundColor(Color(theme.text))
                .lineSpacing(6)
                .textSelection(.enabled)
        case .forgot:
            heading("forgot.title", "forgot.description")
            field($email, say("forgot.email"), .email) { run { await flow.requestReset(email: email) } }
        case .reset(let address):
            heading("reset.title", "reset.description", ["email": address])
            field($code, say("reset.code"), .code) {}
            field($password, say("reset.password"), .newPassword) { run { await flow.resetPassword(code: code, password: password) } }
        case .signIn, .done:
            EmptyView()
        }
    }

    /// "Setup key: ABCD…", with the key in a monospaced face and selectable.
    private func secretLine(_ secret: String) -> some View {
        let name = Text(verbatim: say("enroll.secret") + ": ").foregroundColor(Color(theme.muted))
        let value = Text(verbatim: secret).font(.system(size: 15, design: .monospaced)).foregroundColor(Color(theme.text))
        return (name + value)
            .font(themeFont(theme, size: 16, weight: .regular))
            .textSelection(.enabled)
    }

    private func confirmEmail(_ needsPassword: Bool) {
        run { await flow.confirmEmail(code: code, password: needsPassword ? password : nil) }
    }

    @ViewBuilder
    private var message: some View {
        if let error = state.error {
            Text(translateError(error.code, locale))
                .font(themeFont(theme, size: 14, weight: .regular))
                .foregroundColor(Color(theme.error))
        } else if let notice = state.notice {
            Text(say(notice))
                .font(themeFont(theme, size: 14, weight: .regular))
                .foregroundColor(Color(theme.text))
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state.step {
        case .verifyEmail(_, let needsPassword):
            primary(say("verify.submit")) { confirmEmail(needsPassword) }
            link(say("verify.resend")) { run { await flow.resendEmail() } }
        case .mfa:
            primary(say("mfa.submit")) { run { await flow.verifyMfa(code: code) } }
        case .mfaEnroll:
            primary(say("enroll.submit")) { run { await flow.confirmEnrollment(code: code) } }
        case .recoveryCodes:
            primary(say("recovery.done")) { run { await flow.finishRecovery() } }
        case .forgot:
            primary(say("forgot.submit")) { run { await flow.requestReset(email: email) } }
        case .reset:
            primary(say("reset.submit")) { run { await flow.resetPassword(code: code, password: password) } }
        case .signIn, .done:
            EmptyView()
        }
    }
}
#endif
