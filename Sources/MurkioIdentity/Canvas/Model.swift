import Foundation

/// A canvas text: the default and its translations by locale.
public struct LocalizedText: Equatable, Sendable {
    public let fallback: String
    public let translations: [String: String]

    public init(_ fallback: String, _ translations: [String: String] = [:]) {
        self.fallback = fallback
        self.translations = translations
    }

    /// The translation of the exact locale, then of its language, then the default text.
    public func pick(_ locale: String) -> String {
        let normalized = normalizeLocale(locale)
        return translations[normalized] ?? translations[languageOf(normalized)] ?? fallback
    }
}

/// The kinds of element a canvas can hold. The raw value is the name in the canvas document.
public enum CanvasElementType: String, CaseIterable, Sendable {
    case emailInput = "email_input"
    case passwordInput = "password_input"
    case keepLogged = "keep_logged"
    case loginButton = "login_button"
    case registerButton = "register_button"
    case forgotPasswordLink = "forgot_password_link"
    case oauthButton = "oauth_button"
    case errorMessage = "error_message"
    case text
    case link
    case image
    case shape
    case divider

    /// Decorative elements never take a touch and are painted under the interactive ones.
    public var decorative: Bool {
        self == .text || self == .image || self == .shape || self == .divider
    }

    /// The elements that only make sense with the password login.
    public var needsPassword: Bool {
        switch self {
        case .emailInput, .passwordInput, .keepLogged, .loginButton, .registerButton, .forgotPasswordLink: return true
        default: return false
        }
    }
}

/// Horizontal alignment of an element's text.
public enum CanvasTextAlign: String, Sendable { case left, center, right }

/// The shadow presets of a canvas style.
public enum CanvasShadow: String, Sendable { case none, sm, md, lg }

/// A color of the canvas: red, green, blue and alpha, each from 0 to 255.
public struct CanvasColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8
}

/// The allowed style of an element. A nil field means "the default of the element".
public struct CanvasStyle: Equatable, Sendable {
    public var color: CanvasColor?
    public var background: CanvasColor?
    public var borderColor: CanvasColor?
    public var borderWidth: Int?
    public var radius: Int?
    public var fontSize: Int?
    public var fontWeight: Int?
    public var textAlign: CanvasTextAlign?
    public var padding: Int?
    public var opacity: Double?
    public var shadow: CanvasShadow?

    public init() {}
}

/// One element of a screen: what it is, its texts and its style.
public struct CanvasElement: Equatable, Sendable, Identifiable {
    public let id: String
    public let type: CanvasElementType
    public var style = CanvasStyle()
    /// Inputs, buttons, the link to "forgot password", the divider.
    public var label: LocalizedText?
    /// Inputs.
    public var placeholder: LocalizedText?
    /// `text` and `link`.
    public var text: LocalizedText?
    /// `image`.
    public var alt: LocalizedText?
    /// `password_input`: show the button that reveals the password.
    public var showToggle = false
    /// `keep_logged`: starts checked.
    public var defaultChecked = false
    /// `oauth_button`.
    public var provider: String?
    /// `text`: `body` (or empty), `h1`, `h2`, `h3`.
    public var variant = ""
    /// `link`: an https URL or a site path.
    public var href: String?
    /// `image`: an https URL or a `data:` image.
    public var src: String?

    init(id: String, type: CanvasElementType) {
        self.id = id
        self.type = type
    }

    public var isHeading: Bool { variant == "h1" || variant == "h2" || variant == "h3" }
}

/// Where an element sits in a layout.
public struct CanvasItem: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let w: Int
    public let h: Int
    public let z: Int
    public let hidden: Bool
}

/// The frame of a screen at one size and where each element goes in it.
public struct CanvasLayout: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Nil for a transparent frame.
    public let background: CanvasColor?
    public internal(set) var items: [String: CanvasItem]
}

/// A screen: its elements (the content) and its layouts (the positions).
public struct CanvasScreen: Equatable, Sendable {
    public let elements: [CanvasElement]
    public let desktop: CanvasLayout
    public let mobile: CanvasLayout?
}

/// The font of a canvas.
public enum CanvasFont: String, Sendable {
    case systemSans = "system-sans"
    case systemSerif = "system-serif"
    case systemMono = "system-mono"
    case inherit
}

/// The colors, the font and the corner radius of a canvas.
public struct CanvasTheme: Equatable, Sendable {
    public let font: CanvasFont
    public let radius: Int
    public let primary: CanvasColor
    public let onPrimary: CanvasColor
    public let text: CanvasColor
    public let muted: CanvasColor
    public let background: CanvasColor
    public let surface: CanvasColor
    public let border: CanvasColor
    public let error: CanvasColor
}

/// A validated canvas, ready to draw. Without `signUp` the sign-up uses the sign-in screen.
public struct CanvasDocument: Equatable, Sendable {
    public let theme: CanvasTheme
    public let signIn: CanvasScreen
    public let signUp: CanvasScreen?
}
