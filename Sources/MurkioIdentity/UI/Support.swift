#if canImport(SwiftUI)
import SwiftUI

extension Color {
    init(_ color: CanvasColor) {
        self.init(
            .sRGB,
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255,
            opacity: Double(color.alpha) / 255
        )
    }
}

extension ElementLook {
    var weight: Font.Weight {
        switch fontWeight {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    /// Where a single line of text sits in its box.
    func alignment(top: Bool) -> Alignment {
        switch align {
        case .center: return top ? .top : .center
        case .right: return top ? .topTrailing : .trailing
        case .left: return top ? .topLeading : .leading
        }
    }

    var textAlignment: TextAlignment {
        switch align {
        case .center: return .center
        case .right: return .trailing
        case .left: return .leading
        }
    }

    func font(_ theme: CanvasTheme) -> Font {
        themeFont(theme, size: fontSize, weight: weight)
    }
}

/// The font of a canvas theme at a size. `inherit` uses the system font too:
/// SwiftUI has no way to read the typeface an app set around a view.
func themeFont(_ theme: CanvasTheme, size: Double, weight: Font.Weight) -> Font {
    let design: Font.Design
    switch theme.font {
    case .systemSerif: design = .serif
    case .systemMono: design = .monospaced
    case .systemSans, .inherit: design = .default
    }
    return .system(size: CGFloat(size), weight: weight, design: design)
}

/// Paints the box of an element (padding, background, border, shadow and
/// opacity) around a view that already fills it.
struct ElementBox: ViewModifier {
    let look: ElementLook
    /// True in the canvas, where the box has a fixed frame to fill; false in a
    /// flowing layout, where it only grows sideways.
    var fill = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(look.radius), style: .continuous)
        // The border is drawn inside the box, so the content starts after it, like a CSS border-box.
        let inset = look.hasBorder ? look.borderWidth : 0
        content
            .padding(.horizontal, CGFloat(look.paddingX + inset))
            .padding(.vertical, CGFloat(look.paddingY + inset))
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil)
            .background(shape.fill(look.background.map { Color($0) } ?? Color.clear))
            .overlay(shape.strokeBorder(look.borderColor.map { Color($0) } ?? Color.clear, lineWidth: look.hasBorder ? CGFloat(look.borderWidth) : 0))
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            .opacity(look.opacity)
    }

    // The CSS shadows of the web canvas: sm 0 1 2 at 8%, md 0 4 12 at 12%, lg 0 12 32 at 18%.
    private var shadowColor: Color {
        switch look.shadow {
        case .none: return .clear
        case .sm: return Color.black.opacity(0.08)
        case .md: return Color.black.opacity(0.12)
        case .lg: return Color.black.opacity(0.18)
        }
    }

    private var shadowRadius: CGFloat {
        switch look.shadow {
        case .none: return 0
        case .sm: return 1
        case .md: return 6
        case .lg: return 16
        }
    }

    private var shadowY: CGFloat {
        switch look.shadow {
        case .none: return 0
        case .sm: return 1
        case .md: return 4
        case .lg: return 12
        }
    }
}

extension View {
    func elementBox(_ look: ElementLook, fill: Bool = true) -> some View {
        modifier(ElementBox(look: look, fill: fill))
    }
}

/// What a text field of the SDK holds, which decides its keyboard and what a
/// password manager is told.
enum FieldKind {
    case email, password, newPassword, code
}

extension View {
    /// The keyboard and autofill hints of a field. They only exist on iOS.
    @ViewBuilder
    func fieldTraits(_ kind: FieldKind) -> some View {
        #if os(iOS)
        switch kind {
        case .email:
            self.keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).disableAutocorrection(true)
        case .password:
            self.textContentType(.password).textInputAutocapitalization(.never).disableAutocorrection(true)
        case .newPassword:
            self.textContentType(.newPassword).textInputAutocapitalization(.never).disableAutocorrection(true)
        case .code:
            self.keyboardType(.asciiCapable).textContentType(.oneTimeCode).textInputAutocapitalization(.never).disableAutocorrection(true)
        }
        #else
        self.disableAutocorrection(true)
        #endif
    }
}

/// The check of the "keep me signed in" box.
struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.30))
        return path
    }
}

/// The 18-point box of the "keep me signed in" choice.
@MainActor
struct CheckBox: View {
    let checked: Bool
    let accent: Color
    let onAccent: Color
    let outline: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack {
            if checked {
                shape.fill(accent)
                CheckMark().stroke(onAccent, style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
            } else {
                shape.strokeBorder(outline, lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Reports the width a view was given, so the canvas can pick its layout.
struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports where each element of the canvas ended up, in the frame's coordinates.
struct ElementFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
#endif
