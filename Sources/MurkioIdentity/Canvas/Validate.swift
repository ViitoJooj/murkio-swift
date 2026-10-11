import Foundation

// The server validates every canvas before it is stored, but the SDK checks
// it again before drawing it in the customer's app (defense in depth: a bug
// or a compromised dashboard must not become a fake link or an invisible
// overlay on every login screen). The rules mirror the server's structural
// ones (libs/spec/canvas); an element that breaks them is dropped, a style
// value out of range is ignored, and a document without what a login needs
// is refused so the caller falls back to the default canvas.

private let providers = ["google", "github", "apple", "facebook", "x"]
private let colorNames = ["primary", "on_primary", "text", "muted", "background", "surface", "border", "error"]
private let styleKeys: Set<String> = [
    "color", "background", "border_color", "border_width", "radius", "font_size", "font_weight", "text_align",
    "padding", "opacity", "shadow",
]
private let variants = ["", "body", "h1", "h2", "h3"]
private let maxElements = 150
private let maxDataImages = 4
private let maxDataImageChars = 87384 // ceil(64 KiB / 3) * 4

private func nibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
}

/// Parses a canvas color (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, alpha
/// last). Nil when it is not one.
func parseColor(_ value: JSONValue?) -> CanvasColor? {
    guard let text = value?.string, text.hasPrefix("#") else { return nil }
    var digits: [UInt8] = []
    for byte in text.utf8.dropFirst() {
        guard let digit = nibble(byte) else { return nil }
        digits.append(digit)
    }
    guard [3, 4, 6, 8].contains(digits.count) else { return nil }
    if digits.count <= 4 { digits = digits.flatMap { [$0, $0] } }
    if digits.count == 6 { digits += [15, 15] }
    func byte(_ at: Int) -> UInt8 { digits[at] << 4 | digits[at + 1] }
    return CanvasColor(red: byte(0), green: byte(2), blue: byte(4), alpha: byte(6))
}

private func isInt(_ value: JSONValue?, _ low: Int, _ high: Int) -> Bool {
    guard let number = value?.number, number.isFinite, number == number.rounded() else { return false }
    return number >= Double(low) && number <= Double(high)
}

private func int(_ value: JSONValue?) -> Int {
    Int(value?.number ?? 0)
}

private func cleanText(_ value: JSONValue?, maxChars: Int, multiline: Bool) -> Bool {
    guard let text = value?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    var length = 0
    for scalar in text.unicodeScalars {
        length += 1
        if length > maxChars { return false }
        let code = scalar.value
        if code == 0x0A, multiline { continue }
        if code < 0x20 || (0x7F...0x9F).contains(code) || (0x202A...0x202E).contains(code) || (0x2066...0x2069).contains(code) {
            return false
        }
    }
    return true
}

private func isLocale(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count <= 2, let language = parts.first, (2...3).contains(language.utf8.count),
          language.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) })
    else { return false }
    if parts.count == 1 { return true }
    return parts[1].utf8.count == 2 && parts[1].utf8.allSatisfy { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }
}

private func text(_ value: JSONValue?, maxChars: Int = 120, multiline: Bool = false) -> LocalizedText? {
    guard let value, value.object != nil, cleanText(value["default"], maxChars: maxChars, multiline: multiline),
          let fallback = value["default"]?.string
    else { return nil }
    var translations: [String: String] = [:]
    if let raw = value["i18n"], !raw.isNull {
        guard let i18n = raw.object, i18n.count <= 20 else { return nil }
        for (locale, translation) in i18n {
            guard isLocale(locale), cleanText(translation, maxChars: maxChars, multiline: multiline), let string = translation.string
            else { return nil }
            translations[locale] = string
        }
    }
    return LocalizedText(fallback, translations)
}

private func hasSpaceOrBackslash(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0 == "\\" || $0.properties.isWhitespace }
}

/// True for an absolute https URL without credentials.
func isHttpsURL(_ value: JSONValue?) -> Bool {
    guard let text = value?.string, text.utf8.count <= 2048, !hasSpaceOrBackslash(text), text.hasPrefix("https://") else {
        return false
    }
    let rest = text.dropFirst("https://".count)
    let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    guard !authority.isEmpty, !authority.contains("@") else { return false }
    if authority.hasPrefix("[") { return true }
    let host = authority.lastIndex(of: ":").map { authority[..<$0] } ?? authority
    return !host.isEmpty
}

/// True for what a canvas link may point to: an https URL or a site path.
func isSafeHref(_ value: JSONValue?) -> Bool {
    guard let text = value?.string else { return false }
    if text.hasPrefix("/") {
        return text.utf8.count <= 2048 && !text.hasPrefix("//") && !hasSpaceOrBackslash(text)
    }
    return isHttpsURL(value)
}

private let dataPrefixes = ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/gif;base64,"]

private func isDataImage(_ value: String) -> Bool {
    guard let prefix = dataPrefixes.first(where: { value.hasPrefix($0) }) else { return false }
    var data = Array(value.utf8.dropFirst(prefix.utf8.count))
    var padding = 0
    while data.last == UInt8(ascii: "=") {
        data.removeLast()
        padding += 1
    }
    return !data.isEmpty && padding <= 2 && data.allSatisfy { byte in
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/")
    }
}

private func isImageSource(_ value: JSONValue?) -> Bool {
    if isHttpsURL(value) { return true }
    guard let text = value?.string else { return false }
    return text.utf8.count <= maxDataImageChars + 32 && isDataImage(text)
}

private func present(_ value: JSONValue?) -> Bool {
    guard let value else { return false }
    return !value.isNull
}

/// Builds the element from its props, or nil when a prop breaks a rule.
/// Unknown props are simply not read.
private func element(id: String, type: CanvasElementType, props: JSONValue) -> CanvasElement? {
    func optional(_ key: String) -> LocalizedText? { present(props[key]) ? text(props[key]) : nil }
    func invalidOptional(_ key: String) -> Bool { present(props[key]) && text(props[key]) == nil }
    var element = CanvasElement(id: id, type: type)

    switch type {
    case .emailInput, .passwordInput:
        guard let label = text(props["label"]), !invalidOptional("placeholder") else { return nil }
        element.label = label
        element.placeholder = optional("placeholder")
        element.showToggle = type == .passwordInput && props["show_toggle"]?.bool == true
    case .keepLogged, .loginButton, .registerButton, .forgotPasswordLink:
        guard let label = text(props["label"]) else { return nil }
        element.label = label
        element.defaultChecked = type == .keepLogged && props["default_checked"]?.bool == true
    case .oauthButton:
        guard let provider = props["provider"]?.string, providers.contains(provider), !invalidOptional("label") else { return nil }
        element.provider = provider
        element.label = optional("label")
    case .text:
        guard let content = text(props["text"], maxChars: 500, multiline: true) else { return nil }
        if present(props["variant"]) {
            guard let variant = props["variant"]?.string, variants.contains(variant) else { return nil }
            element.variant = variant
        }
        element.text = content
    case .link:
        guard let content = text(props["text"]), isSafeHref(props["href"]) else { return nil }
        element.text = content
        element.href = props["href"]?.string
    case .image:
        guard !invalidOptional("alt"), isImageSource(props["src"]) else { return nil }
        element.alt = optional("alt")
        element.src = props["src"]?.string
    case .divider:
        guard !invalidOptional("label") else { return nil }
        element.label = optional("label")
    case .errorMessage, .shape:
        break
    }
    return element
}

private func style(_ value: JSONValue?, problems: inout [String], path: String) -> CanvasStyle {
    var style = CanvasStyle()
    guard let value, let map = value.object else { return style }
    var read: Set<String> = []

    func color(_ key: String) -> CanvasColor? {
        guard let parsed = parseColor(map[key]) else { return nil }
        read.insert(key)
        return parsed
    }
    func integer(_ key: String, _ low: Int, _ high: Int) -> Int? {
        guard isInt(map[key], low, high) else { return nil }
        read.insert(key)
        return int(map[key])
    }

    style.color = color("color")
    style.background = color("background")
    style.borderColor = color("border_color")
    style.borderWidth = integer("border_width", 0, 8)
    style.radius = integer("radius", 0, 999)
    style.fontSize = integer("font_size", 12, 72)
    if isInt(map["font_weight"], 100, 900), int(map["font_weight"]) % 100 == 0 {
        style.fontWeight = int(map["font_weight"])
        read.insert("font_weight")
    }
    if let align = map["text_align"]?.string.flatMap(CanvasTextAlign.init(rawValue:)) {
        style.textAlign = align
        read.insert("text_align")
    }
    style.padding = integer("padding", 0, 64)
    if let opacity = map["opacity"]?.number, opacity >= 0, opacity <= 1 {
        style.opacity = opacity
        read.insert("opacity")
    }
    if let shadow = map["shadow"]?.string.flatMap(CanvasShadow.init(rawValue:)) {
        style.shadow = shadow
        read.insert("shadow")
    }

    for key in map.keys.sorted() where !styleKeys.contains(key) || !read.contains(key) {
        problems.append("\(path).\(key): ignored style")
    }
    return style
}

private func layout(_ value: JSONValue?, problems: inout [String], path: String) -> CanvasLayout? {
    guard let value, let rawItems = value["items"]?.object, isInt(value["width"], 240, 1920), isInt(value["height"], 240, 2400) else {
        problems.append("\(path): invalid layout")
        return nil
    }
    let width = int(value["width"])
    let height = int(value["height"])
    var items: [String: CanvasItem] = [:]
    for id in rawItems.keys.sorted() {
        let item = rawItems[id]
        if let item, item.object != nil, isInt(item["x"], 0, width), isInt(item["y"], 0, height), isInt(item["w"], 1, width),
           isInt(item["h"], 1, height), int(item["x"]) + int(item["w"]) <= width, int(item["y"]) + int(item["h"]) <= height,
           isInt(item["z"], 0, 1000) {
            items[id] = CanvasItem(
                x: int(item["x"]), y: int(item["y"]), w: int(item["w"]), h: int(item["h"]), z: int(item["z"]),
                hidden: item["hidden"]?.bool == true
            )
        } else {
            problems.append("\(path).items.\(id): invalid item")
        }
    }
    return CanvasLayout(width: width, height: height, background: parseColor(value["background"]?["color"]), items: items)
}

private func isElementId(_ value: String) -> Bool {
    (1...32).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }
}

private func screen(_ value: JSONValue?, problems: inout [String], path: String, images: inout Int) -> CanvasScreen? {
    guard let value, let rawElements = value["elements"]?.array, let layouts = value["layouts"], layouts.object != nil else {
        problems.append("\(path): invalid screen")
        return nil
    }
    guard var desktop = layout(layouts["desktop"], problems: &problems, path: "\(path).layouts.desktop") else { return nil }
    var mobile = present(layouts["mobile"]) ? layout(layouts["mobile"], problems: &problems, path: "\(path).layouts.mobile") : nil

    if rawElements.count > maxElements { problems.append("\(path).elements: more than \(maxElements) elements") }

    var ids: Set<String> = []
    var elements: [CanvasElement] = []
    for (index, entry) in rawElements.prefix(maxElements).enumerated() {
        let at = "\(path).elements[\(index)]"
        guard entry.object != nil, let id = entry["id"]?.string, isElementId(id), !ids.contains(id) else {
            problems.append("\(at): invalid or duplicate id")
            continue
        }
        ids.insert(id)

        let typeName = entry["type"]?.string ?? ""
        let props: JSONValue? = present(entry["props"]) ? (entry["props"]?.object != nil ? entry["props"] : nil) : .object([:])
        guard let type = CanvasElementType(rawValue: typeName), let props, var built = element(id: id, type: type, props: props) else {
            problems.append("\(at): invalid \(typeName)")
            continue
        }
        if type == .image, built.src?.hasPrefix("data:") == true {
            images += 1
            if images > maxDataImages {
                problems.append("\(at): more than \(maxDataImages) embedded images")
                continue
            }
        }
        if desktop.items[id] == nil || (mobile != nil && mobile?.items[id] == nil) {
            problems.append("\(at): missing from a layout")
            continue
        }
        built.style = style(entry["style"], problems: &problems, path: "\(at).style")
        elements.append(built)
    }

    for id in desktop.items.keys.sorted() where !ids.contains(id) {
        problems.append("\(path): item \(id) has no element")
        desktop.items[id] = nil
    }
    if var layout = mobile {
        for id in layout.items.keys.sorted() where !ids.contains(id) {
            problems.append("\(path): item \(id) has no element")
            layout.items[id] = nil
        }
        mobile = layout
    }
    return CanvasScreen(elements: elements, desktop: desktop, mobile: mobile)
}

/// The result of checking a canvas document: the cleaned canvas (nil when it
/// cannot be drawn: wrong schema, no sign_in screen or desktop layout, a
/// broken theme) and everything that was wrong, for logging and tests.
public struct SanitizeResult: Sendable {
    public let document: CanvasDocument?
    public let problems: [String]
}

/// Checks a canvas document before it is drawn.
public func sanitizeDocument(_ value: JSONValue?) -> SanitizeResult {
    guard let value, value["schema"]?.number == 1, let theme = value["theme"], theme.object != nil,
          let screens = value["screens"]?.object
    else { return SanitizeResult(document: nil, problems: ["not a schema 1 canvas"]) }

    var colors: [String: CanvasColor] = [:]
    for name in colorNames {
        if let color = parseColor(theme["colors"]?[name]) { colors[name] = color }
    }
    guard let font = theme["font"]?.string.flatMap(CanvasFont.init(rawValue:)), isInt(theme["radius"], 0, 32),
          let primary = colors["primary"], let onPrimary = colors["on_primary"], let textColor = colors["text"],
          let muted = colors["muted"], let background = colors["background"], let surface = colors["surface"],
          let border = colors["border"], let error = colors["error"]
    else { return SanitizeResult(document: nil, problems: ["invalid theme"]) }

    var problems: [String] = []
    for name in screens.keys.sorted() where name != "sign_in" && name != "sign_up" {
        problems.append("screens.\(name): unknown screen")
    }

    var images = 0
    guard let signIn = screen(screens["sign_in"], problems: &problems, path: "screens.sign_in", images: &images) else {
        return SanitizeResult(document: nil, problems: problems)
    }
    let signUp = present(screens["sign_up"]) ? screen(screens["sign_up"], problems: &problems, path: "screens.sign_up", images: &images) : nil

    let document = CanvasDocument(
        theme: CanvasTheme(
            font: font, radius: int(theme["radius"]), primary: primary, onPrimary: onPrimary, text: textColor, muted: muted,
            background: background, surface: surface, border: border, error: error
        ),
        signIn: signIn,
        signUp: signUp
    )
    return SanitizeResult(document: document, problems: problems)
}

/// True when the screen still has what a password login needs (email, password and a submit action).
func canSignIn(_ screen: CanvasScreen) -> Bool {
    let types = Set(screen.elements.map { $0.type })
    return types.contains(.emailInput) && types.contains(.passwordInput)
        && (types.contains(.loginButton) || types.contains(.registerButton))
}

/// True when the screen can sign a user in with what the application has turned on.
func isUsable(_ screen: CanvasScreen, config: PublicConfig?) -> Bool {
    if let config, !config.passwordEnabled {
        return screen.elements.contains { $0.type == .oauthButton && config.oauthProviders.contains($0.provider ?? "") }
    }
    return canSignIn(screen)
}

private let builtInCanvas: CanvasDocument = {
    guard let document = sanitizeDocument(JSONValue.parse(Spec.defaultCanvas)).document else {
        fatalError("the built-in canvas is invalid")
    }
    return document
}()

/// The default canvas (libs/spec/canvas/default.json).
public func defaultCanvas() -> CanvasDocument {
    builtInCanvas
}

/// The canvas to draw: the published one when it passes the SDK's own checks
/// and still has what the application's login needs, else the default one.
/// `onProblems` receives what was skipped.
func pickCanvas(_ raw: JSONValue?, config: PublicConfig?, onProblems: ([String]) -> Void = { _ in }) -> CanvasDocument {
    guard let raw, !raw.isNull else { return defaultCanvas() }
    let result = sanitizeDocument(raw)
    if !result.problems.isEmpty { onProblems(result.problems) }
    if let document = result.document, isUsable(document.signIn, config: config) { return document }
    return defaultCanvas()
}
