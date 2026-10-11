import Foundation

/// One problem reported by the API.
public struct MurkioErrorDetail: Equatable, Sendable {
    public let code: String
    public let message: String
    public let path: String?
}

/// Every failure the SDK reports. `code` is the stable API code (`rsb-00`,
/// `bss-01`...), `network` when the request never got an answer and `unknown`
/// for anything without a code. Show `localized()` to users and use `code` in
/// your own logic: the API message is English only.
public struct MurkioError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let status: Int
    public let details: [MurkioErrorDetail]
    public let message: String

    public init(_ code: String, status: Int = 0, details: [MurkioErrorDetail] = [], message: String? = nil) {
        self.code = code
        self.status = status
        self.details = details
        self.message = message ?? details.first?.message ?? code
    }

    /// The message to show the user, in `locale`.
    public func localized(_ locale: String = "en") -> String {
        translateError(code, locale)
    }

    public var description: String { "MurkioError(\(code), \(status)): \(message)" }

    /// Reads the error of an API answer.
    static func fromResponse(status: Int, body: JSONValue?) -> MurkioError {
        let details: [MurkioErrorDetail] = (body?["details"]?.array ?? []).compactMap { item in
            guard let code = item["code"]?.string else { return nil }
            return MurkioErrorDetail(code: code, message: item["message"]?.string ?? "", path: item["path"]?.string)
        }
        return MurkioError(details.first?.code ?? "unknown", status: status, details: details)
    }

    /// Any error as a `MurkioError` (`unknown` when it is something else).
    static func from(_ error: Error) -> MurkioError {
        (error as? MurkioError) ?? MurkioError("unknown", message: String(describing: error))
    }
}

/// Translates an error code (or `oauth.<error>` from a social sign-in return)
/// for the user.
public func translateError(_ code: String, _ locale: String = "en") -> String {
    let table = tableFor(Spec.errors, locale)
    return table[code] ?? table["unknown"] ?? Spec.errors["en"]?["unknown"] ?? code
}
