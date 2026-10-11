import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Proves consent through the real setting owner and real Unix sockets: while the test holds the main actor, the
/// server cannot build a payload (it needs `UsageStore` on the main actor), so an accepted client is guaranteed to be
/// waiting when the setting changes.
@MainActor
struct AppUsageSocketConsentTests {
    @Test
    func `withdrawing sharing revokes a waiting client and re-enabling does not answer it`() async throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cbc-\(UUID().uuidString.prefix(8)).sock")
        defer {
            unlink(path)
            unlink(AppUsageSocketServer.ownerLockPath(forSocketPath: path))
        }
        let (delegate, settings) = Self.makeDelegate()
        delegate.appUsageSocketPath = path
        settings.shareUsageWithCLI = true
        delegate.observeAppUsageSocketSetting()
        defer {
            settings.shareUsageWithCLI = false
            delegate.observeAppUsageSocketSetting()
        }
        let firstServer = try #require(delegate.appUsageSocketServer)
        try #require(FileManager.default.fileExists(atPath: path))

        // From here until the first `await`, the main actor is held, so client A's payload cannot be built.
        let clientA = try #require(AppUsageSocket.connectedSocket(path: path, timeout: 30))
        defer { close(clientA) }
        try #require(Self.waitSynchronously { firstServer.pendingClientCount == 1 })

        settings.shareUsageWithCLI = false
        #expect(delegate.appUsageSocketServer == nil)
        #expect(!FileManager.default.fileExists(atPath: path))

        settings.shareUsageWithCLI = true

        // Yield: the re-armed observer starts a fresh server and the old payload build finally runs.
        try #require(await Self.waitUntil {
            delegate.appUsageSocketServer != nil && FileManager.default.fileExists(atPath: path)
        })
        #expect(delegate.appUsageSocketServer !== firstServer)
        let received = try #require(await Self.readPayload(path))
        #expect(received.providers.map(\.provider) == ["claude"])

        // The old reply has resolved by now; any byte it delivered would still be buffered for client A.
        try #require(await Self.waitUntil {
            firstServer.pendingClientCount == 0 && firstServer.inFlightClientCount == 0
        })
        let bytesReceivedByA = await Self.readToEOF(clientA)
        #expect(bytesReceivedByA == 0)
    }

    private static func makeDelegate() -> (AppDelegate, SettingsStore) {
        _ = NSApplication.shared
        let settings = testSettingsStore(
            suiteName: "AppUsageSocketConsentTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        enableTestProviders([.claude], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: "/synthetic", fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)
        let managedCoordinator = ManagedCodexAccountCoordinator()
        let delegate = AppDelegate()
        delegate.configure(.init(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            selection: PreferencesSelection(),
            managedCodexAccountCoordinator: managedCoordinator,
            codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator(
                settingsStore: settings,
                usageStore: store,
                managedAccountCoordinator: managedCoordinator)))
        return (delegate, settings)
    }

    /// Polls without suspending, so the main actor stays held (bounded at 5 seconds).
    private static func waitSynchronously(_ condition: () -> Bool) -> Bool {
        for _ in 0..<500 {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// Polls with suspension so main-actor work can run (bounded at 5 seconds).
    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Reads off the main actor, which the server needs to build the payload.
    private static func readPayload(_ path: String) async -> AppUsageSocketPayload? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: AppUsageSocket.read(path: path, timeout: 30))
            }
        }
    }

    private static func readToEOF(_ fd: Int32) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var total = 0
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes { raw in
                        Darwin.read(fd, raw.baseAddress, raw.count)
                    }
                    if count > 0 {
                        total += count
                    } else if count == 0 {
                        continuation.resume(returning: total)
                        return
                    } else if errno != EINTR {
                        continuation.resume(returning: nil)
                        return
                    }
                }
            }
        }
    }
}
