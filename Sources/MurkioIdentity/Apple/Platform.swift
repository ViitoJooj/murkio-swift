import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Knows whether the app is in the foreground, and says when it comes back
/// to it. Off Apple platforms the app counts as always in the foreground.
final class AppLifecycle: @unchecked Sendable {
    static let shared = AppLifecycle()

    private let lock = NSLock()
    private var foreground = true
    private var handler: (@Sendable () -> Void)?

    private init() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.changed(to: true)
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.changed(to: false)
        }
        #elseif canImport(AppKit)
        // A Mac app keeps running behind other windows: it only matters when it becomes active again.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.changed(to: true)
        }
        #endif
    }

    var isForeground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return foreground
    }

    /// Called every time the app comes to the foreground.
    var onForeground: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
        set {
            lock.lock()
            handler = newValue
            lock.unlock()
        }
    }

    private func changed(to foreground: Bool) {
        lock.lock()
        self.foreground = foreground
        let handler = self.handler
        lock.unlock()
        if foreground { handler?() }
    }
}

/// The Keychain on Apple platforms; memory elsewhere (there is no app to keep a session for).
func defaultStorage() -> MurkioStorage {
    #if canImport(Security)
    return KeychainStorage()
    #else
    return MurkioMemoryStorage()
    #endif
}

/// Opens a link outside the app: the browser, or whatever app handles it.
@Sendable
func openOutside(_ link: String) -> Bool {
    guard let url = URL(string: link) else { return false }
    #if canImport(UIKit) && !os(watchOS)
    Task { @MainActor in _ = await UIApplication.shared.open(url) }
    return true
    #elseif canImport(AppKit)
    return NSWorkspace.shared.open(url)
    #else
    return false
    #endif
}
