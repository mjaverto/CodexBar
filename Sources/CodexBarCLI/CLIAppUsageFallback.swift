import CodexBarCore
#if os(macOS)
import Foundation
import Security
#endif

/// SSH and other non-GUI macOS sessions cannot read login-keychain secrets (cookie caches, Chromium Safe Storage,
/// Claude Code credentials). There, failed default-account fetches fall back to the running app's usage.
enum CLIAppUsageFallback {
    /// Distinct from provider-reported labels such as Antigravity's desktop-app probe (`app`).
    static let sourceLabel = "codexbar-app"

    /// Nil in GUI sessions (and on Linux), so local behavior there is unchanged. Installed only by the one-shot
    /// `usage`/`cards` commands; the socket is read at most once per run, on the first failing provider.
    static func makeReader() -> (@Sendable (UsageProvider) -> AppUsageSocketPayload.Provider?)? {
        #if os(macOS)
        guard !self.callerHasGraphicSessionAccess() else { return nil }
        let cache = PayloadCache()
        return { provider in
            cache.payload()?.provider(provider)
        }
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func callerHasGraphicSessionAccess() -> Bool {
        var attributes = SessionAttributeBits()
        // Unknown session state keeps the existing local-only behavior.
        guard SessionGetInfo(callerSecuritySession, nil, &attributes) == errSecSuccess else { return true }
        return attributes.contains(.sessionHasGraphicAccess)
    }

    private final class PayloadCache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = false
        private var cached: AppUsageSocketPayload?

        func payload() -> AppUsageSocketPayload? {
            self.lock.lock()
            defer { self.lock.unlock() }
            if !self.loaded {
                self.cached = AppUsageSocket.read()
                self.loaded = true
            }
            return self.cached
        }
    }
    #endif
}
