import CodexBarCore
import Foundation
import Testing

struct AppUsageSocketTests {
    private static let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let payload = AppUsageSocketPayload(providers: [
        AppUsageSocketPayload.Provider(
            provider: .claude,
            usage: UsageSnapshot(
                primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: updatedAt),
            credits: nil),
    ])

    @Test
    func `server hands the app payload to a same user client and cleans up on stop`() async throws {
        let path = Self.temporarySocketPath()
        defer { unlink(path) }
        let server = AppUsageSocketServer(path: path) { Self.payload }
        try server.start()
        defer { server.stop() }

        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let received = try #require(await Self.read(path))
        #expect(received.version == AppUsageSocketPayload.currentVersion)
        #expect(received.providers.map(\.provider) == ["claude"])
        let claude = try #require(received.provider(.claude))
        #expect(claude.usage.updatedAt == Self.updatedAt)
        #expect(claude.usage.primary?.usedPercent == 42)
        #expect(received.provider(.codex) == nil)

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await Self.read(path) == nil)
    }

    @Test
    func `second server leaves a live socket to its running owner`() async throws {
        let path = Self.temporarySocketPath()
        defer { unlink(path) }
        let first = AppUsageSocketServer(path: path) { Self.payload }
        try first.start()
        defer { first.stop() }

        let second = AppUsageSocketServer(path: path) { AppUsageSocketPayload(providers: []) }
        #expect(throws: POSIXError.self) {
            try second.start()
        }
        second.stop()

        let received = try #require(await Self.read(path))
        #expect(received.providers.map(\.provider) == ["claude"])
    }

    @Test
    func `client returns nil when no app is listening`() async {
        #expect(await Self.read(Self.temporarySocketPath()) == nil)
    }

    /// The client blocks on socket I/O; keep it off the cooperative pool the server's payload task needs. The generous
    /// timeout keeps a busy test host from failing a round trip that the 2s production default would cut off.
    private static func read(_ path: String) async -> AppUsageSocketPayload? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: AppUsageSocket.read(path: path, timeout: 30))
            }
        }
    }

    /// Unix socket paths must fit `sun_path` (104 bytes), so keep the name short.
    private static func temporarySocketPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cbs-\(UUID().uuidString.prefix(8)).sock")
    }
}
