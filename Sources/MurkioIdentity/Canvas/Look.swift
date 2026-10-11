import Foundation

/// How an element is painted: the defaults of its type (from the canvas
/// theme) with the element's own style on top. Plain values, so every
/// platform's drawing code reads the same numbers.
public struct ElementLook: Equatable, Sendable {
    public var foreground: CanvasColor
    public var fontSize: Double = 16
    /// 100 to 900, as in the canvas style.
    public var fontWeight = 400
    public var align: CanvasTextAlign = .left
    public var background: CanvasColor?
    public var borderColor: CanvasColor?
    public var borderWidth: Double = 0
    public var radius: Double = 0
    public var paddingX: Double = 0
    public var paddingY: Double = 0
    public var opacity: Double = 1
    public var shadow: CanvasShadow = .none

    public var hasBorder: Bool { borderWidth > 0 && borderColor != nil }
}

/// The look of `element` in a canvas with `theme`.
public func resolveLook(_ element: CanvasElement, theme: CanvasTheme) -> ElementLook {
    var look = ElementLook(foreground: theme.text)
    let radius = Double(theme.radius)

    switch element.type {
    case .emailInput, .passwordInput:
        look.background = theme.surface
        look.borderColor = theme.border
        look.borderWidth = 1
        look.radius = radius
        look.paddingX = 12
    case .loginButton, .registerButton:
        look.foreground = theme.onPrimary
        look.background = theme.primary
        look.radius = radius
        look.fontWeight = 600
        look.align = .center
        look.paddingX = 16
    case .oauthButton:
        look.background = theme.surface
        look.borderColor = theme.border
        look.borderWidth = 1
        look.radius = radius
        look.fontWeight = 600
        look.align = .center
        look.paddingX = 16
    case .forgotPasswordLink, .link:
        look.foreground = theme.primary
        look.fontSize = 14
    case .keepLogged:
        look.fontSize = 14
    case .errorMessage:
        look.foreground = theme.error
        look.fontSize = 14
    case .divider:
        look.foreground = theme.muted
        look.fontSize = 14
    case .text:
        if element.isHeading { look.fontWeight = 700 }
    case .image, .shape:
        break
    }

    let style = element.style
    if let color = style.color { look.foreground = color }
    if let background = style.background { look.background = background }
    if style.borderColor != nil || style.borderWidth != nil {
        // Only a color means a 1px border; only a width takes the color the
        // element already has (its default border, else its text color).
        look.borderWidth = Double(style.borderWidth ?? 1)
        look.borderColor = style.borderColor ?? look.borderColor ?? look.foreground
    }
    if let radius = style.radius { look.radius = Double(radius) }
    if let size = style.fontSize { look.fontSize = Double(size) }
    if let weight = style.fontWeight { look.fontWeight = weight }
    if let align = style.textAlign { look.align = align }
    if let padding = style.padding {
        look.paddingX = Double(padding)
        look.paddingY = Double(padding)
    }
    if let opacity = style.opacity { look.opacity = opacity }
    if let shadow = style.shadow { look.shadow = shadow }
    return look
}

/// The checkbox's starting value. A screen without the checkbox keeps the
/// session, as an app is expected to.
func keepLoggedDefault(_ screen: CanvasScreen, config: PublicConfig?) -> Bool {
    guard let element = screen.elements.first(where: { $0.type == .keepLogged && isVisible($0, config: config, oauth: true) }) else {
        return true
    }
    return element.defaultChecked
}
