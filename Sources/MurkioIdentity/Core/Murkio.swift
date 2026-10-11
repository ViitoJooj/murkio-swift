import Foundation

/// The entry point of the SDK. The app only declares its publishable key, in
/// its `Info.plist`:
///
/// ```xml
/// <key>MurkioPublishableKey</key>
/// <string>pk_...</string>
/// ```
///
/// and the SDK sets itself up the first time it is used. To do it in code
/// instead (or to pass more options), call `Murkio.configure` when the app
/// starts.
public enum Murkio {
    /// The `Info.plist` keys the SDK reads.
    public static let publishableKeyInfoKey = "MurkioPublishableKey"
    public static let apiURLInfoKey = "MurkioAPIURL"
    public static let oauthRedirectURLInfoKey = "MurkioOAuthRedirectURL"

    private static let lock = NSLock()
    private static var instance: MurkioClient?

    /// The app's client. Without a configured key this stops the app with a
    /// message that says what to add.
    public static var client: MurkioClient {
        if let existing = current { return existing }
        guard let key = Bundle.main.object(forInfoDictionaryKey: publishableKeyInfoKey) as? String else {
            fatalError(
                "Murkio is not configured. Add \(publishableKeyInfoKey) (pk_...) to the app's Info.plist, "
                    + "or call Murkio.configure(publishableKey: \"pk_...\") when the app starts."
            )
        }
        return configure(
            publishableKey: key,
            apiURL: Bundle.main.object(forInfoDictionaryKey: apiURLInfoKey) as? String,
            oauthRedirectURL: Bundle.main.object(forInfoDictionaryKey: oauthRedirectURLInfoKey) as? String
        )
    }

    public static var isConfigured: Bool { current != nil }

    /// Creates the app's client and restores the session of the last run.
    /// Calling it again with the same key returns the same client.
    ///
    /// - Parameters:
    ///   - publishableKey: the application's `pk_...` key, the only required setting.
    ///   - locale: language of the built-in screens and error messages. Defaults to the device's.
    ///   - oauthRedirectURL: the https Universal Link the social sign-in comes back to. Without it
    ///     the social buttons are hidden.
    @discardableResult
    public static func configure(
        publishableKey: String,
        apiURL: String? = nil,
        locale: String? = nil,
        oauthRedirectURL: String? = nil,
        storage: MurkioStorage? = nil,
        transport: MurkioTransport? = nil
    ) -> MurkioClient {
        lock.lock()
        defer { lock.unlock() }
        if let instance, instance.publishableKey == publishableKey { return instance }

        let created: MurkioClient
        do {
            created = try MurkioClient(
                publishableKey: publishableKey,
                apiURL: apiURL,
                locale: locale,
                oauthRedirectURL: oauthRedirectURL,
                storage: storage ?? defaultStorage(),
                transport: transport ?? URLSessionTransport(),
                opener: openOutside,
                isForeground: { AppLifecycle.shared.isForeground }
            )
        } catch {
            fatalError("Murkio.configure: \(MurkioError.from(error).message)")
        }
        AppLifecycle.shared.onForeground = { [weak created] in created?.resumed() }
        instance = created
        Task { await created.start() }
        return created
    }

    /// Makes `client` the app's client. For tests and previews.
    static func use(_ client: MurkioClient?) {
        lock.lock()
        instance = client
        lock.unlock()
    }

    private static var current: MurkioClient? {
        lock.lock()
        defer { lock.unlock() }
        return instance
    }
}
