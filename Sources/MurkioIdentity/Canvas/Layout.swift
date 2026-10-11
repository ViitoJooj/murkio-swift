import Foundation

/// The layout a canvas is drawn with.
public enum CanvasLayoutName: String, Sendable { case desktop, mobile, stack }

/// Layouts only shrink, and never below this: under it the text would not fit
/// the boxes, so the mobile layout (or the stack) takes over.
let minScale = 0.75

let stackPaddingX = 16.0
let stackPaddingY = 24.0
let stackGap = 12.0

/// Picks the layout for the width the canvas really has (its container, not the screen).
func chooseLayout(_ screen: CanvasScreen, width: Double) -> CanvasLayoutName {
    if width >= Double(screen.desktop.width) * minScale { return .desktop }
    if let mobile = screen.mobile, width >= Double(mobile.width) * minScale { return .mobile }
    return .stack
}

/// The elements top to bottom, then left to right, by the desktop layout: the
/// order of focus, of the screen reader and of the stacked layout.
func readingOrder(_ screen: CanvasScreen) -> [CanvasElement] {
    let items = screen.desktop.items
    return screen.elements.enumerated().sorted { a, b in
        guard let first = items[a.element.id], let second = items[b.element.id] else { return a.offset < b.offset }
        if first.y != second.y { return first.y < second.y }
        if first.x != second.x { return first.x < second.x }
        return a.offset < b.offset
    }.map { $0.element }
}

/// Whether the application's config shows the element. A nil `config` shows
/// everything (preview). `oauth` is false when the app has no return link for
/// the social sign-in: a button that cannot come back is hidden.
func isVisible(_ element: CanvasElement, config: PublicConfig?, oauth: Bool) -> Bool {
    if element.type == .oauthButton, !oauth { return false }
    guard let config else { return true }
    if !config.passwordEnabled, element.type.needsPassword { return false }
    if element.type == .oauthButton { return config.oauthProviders.contains(element.provider ?? "") }
    return true
}

/// What "submit" does (the keyboard's action button): `login` on the sign-in
/// screen with a visible login button, else `register`.
func submitAction(_ screen: CanvasScreen, signUp: Bool, config: PublicConfig?, oauth: Bool) -> String {
    let hasLogin = screen.elements.contains { $0.type == .loginButton && isVisible($0, config: config, oauth: oauth) }
    return hasLogin && !signUp ? "login" : "register"
}

/// A box in the frame, in points from its top left corner.
public struct CanvasRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
}

/// Where everything goes for one container width.
public struct CanvasPlacement: Equatable, Sendable {
    public let layout: CanvasLayoutName
    public let frameWidth: Double
    public let frameHeight: Double
    /// Nil for a transparent frame.
    public let background: CanvasColor?
    /// The drawn elements in reading order.
    public let order: [CanvasElement]
    /// The drawn elements bottom to top.
    public let paint: [CanvasElement]
    public let rects: [String: CanvasRect]
}

/// Lays a screen out for a container `width`.
func place(_ screen: CanvasScreen, width: Double, config: PublicConfig?, oauth: Bool) -> CanvasPlacement {
    let name = chooseLayout(screen, width: width)
    let layout = name == .mobile ? (screen.mobile ?? screen.desktop) : screen.desktop
    let frameWidth = min(width, Double(layout.width))
    let shown = readingOrder(screen).filter {
        isVisible($0, config: config, oauth: oauth) && layout.items[$0.id]?.hidden == false
    }
    var rects: [String: CanvasRect] = [:]

    if name == .stack {
        var y = stackPaddingY
        for element in shown {
            let height = Double(layout.items[element.id]?.h ?? 0)
            rects[element.id] = CanvasRect(x: stackPaddingX, y: y, w: frameWidth - 2 * stackPaddingX, h: height)
            y += height + stackGap
        }
        return CanvasPlacement(
            layout: name, frameWidth: frameWidth,
            frameHeight: shown.isEmpty ? 2 * stackPaddingY : y - stackGap + stackPaddingY,
            background: layout.background, order: shown, paint: shown, rects: rects
        )
    }

    let scale = frameWidth / Double(layout.width)
    for element in shown {
        guard let item = layout.items[element.id] else { continue }
        rects[element.id] = CanvasRect(x: Double(item.x) * scale, y: Double(item.y) * scale, w: Double(item.w) * scale, h: Double(item.h) * scale)
    }
    func depth(_ element: CanvasElement) -> Int {
        (element.type.decorative ? 0 : 2000) + (layout.items[element.id]?.z ?? 0)
    }
    let paint = shown.enumerated().sorted { a, b in
        let first = depth(a.element), second = depth(b.element)
        return first != second ? first < second : a.offset < b.offset
    }.map { $0.element }
    return CanvasPlacement(
        layout: name, frameWidth: frameWidth, frameHeight: Double(layout.height) * scale, background: layout.background,
        order: shown, paint: paint, rects: rects
    )
}
