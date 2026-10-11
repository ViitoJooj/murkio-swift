#if canImport(SwiftUI)
import SwiftUI

/// A text field painted by the SDK: the box comes from `look`, and the field
/// inside it is the plain SwiftUI one.
@MainActor
struct MurkioTextField: View {
    @Binding var text: String
    let look: ElementLook
    let theme: CanvasTheme
    /// The accessible name of the field.
    let label: String
    let hint: String
    let kind: FieldKind
    var obscure = false
    var submitLabel: SubmitLabel = .done
    var onSubmit: () -> Void = {}

    var body: some View {
        let prompt = Text(hint).foregroundColor(Color(theme.muted))
        Group {
            if obscure {
                SecureField(label, text: $text, prompt: prompt)
            } else {
                TextField(label, text: $text, prompt: prompt)
            }
        }
        .textFieldStyle(.plain)
        .font(look.font(theme))
        .foregroundColor(Color(look.foreground))
        .multilineTextAlignment(look.textAlignment)
        .fieldTraits(kind)
        .submitLabel(submitLabel)
        .onSubmit(onSubmit)
        .tint(Color(theme.primary))
        .accessibilityLabel(label)
    }
}

/// A button painted by the SDK. `busy` disables and dims it while a request
/// runs. With `underline` it is drawn as a link; `top` aligns its text to the
/// top of the box instead of the middle.
@MainActor
struct MurkioButton: View {
    let label: String
    let look: ElementLook
    let theme: CanvasTheme
    var busy = false
    var underline = false
    var top = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            styled
                .multilineTextAlignment(look.textAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: look.alignment(top: top))
                .elementBox(look)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    private var styled: Text {
        let text = Text(label).font(look.font(theme)).foregroundColor(Color(look.foreground))
        return underline ? text.underline() : text
    }
}
#endif
