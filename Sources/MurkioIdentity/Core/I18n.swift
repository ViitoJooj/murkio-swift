import Foundation

/// `pt_BR` and `pt-BR` are the same locale; the tables use the hyphen.
func normalizeLocale(_ locale: String) -> String {
    locale.replacingOccurrences(of: "_", with: "-")
}

/// The language of a locale, without the region (`pt-BR` is `pt`).
func languageOf(_ locale: String) -> String {
    String(normalizeLocale(locale).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
}

/// The table of a locale: the exact one, the Brazilian one for any
/// Portuguese, English for everything else.
func tableFor(_ tables: [String: [String: String]], _ locale: String) -> [String: String] {
    let normalized = normalizeLocale(locale)
    if let exact = tables[normalized] { return exact }
    return (languageOf(normalized) == "pt" ? tables["pt-BR"] : tables["en"]) ?? [:]
}

/// A text of the built-in screens (email code, two-step verification,
/// password reset), in the given locale. `{name}` is replaced from `params`.
public func murkioString(_ locale: String, _ key: String, _ params: [String: String] = [:]) -> String {
    let template = tableFor(Spec.strings, locale)[key] ?? Spec.strings["en"]?[key] ?? key
    var out = ""
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{") {
        out += rest[rest.startIndex..<open]
        guard let close = rest[open...].firstIndex(of: "}") else {
            rest = rest[open...]
            break
        }
        let name = String(rest[rest.index(after: open)..<close])
        let isName = !name.isEmpty && name.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0.value == 0x5F
        }
        if isName {
            out += params[name] ?? ""
        } else {
            out += rest[open...close]
        }
        rest = rest[rest.index(after: close)...]
    }
    return out + rest
}

private let providerNames = ["google": "Google", "github": "GitHub", "apple": "Apple", "facebook": "Facebook", "x": "X"]

/// The display name of a social sign-in provider.
func providerName(_ provider: String) -> String {
    providerNames[provider] ?? provider
}

/// The language of the device, as a locale tag (`pt-BR`).
func deviceLocale() -> String {
    normalizeLocale(Locale.preferredLanguages.first ?? Locale.current.identifier)
}
