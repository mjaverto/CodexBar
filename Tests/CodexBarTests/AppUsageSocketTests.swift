import Foundation
import Testing
@testable import CodexBarCore

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
    ].compactMap(\.self))

    @Test
    func `server hands the app payload to a same user client and cleans up on stop`() async throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeSocketFiles(path) }
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
        defer { Self.removeSocketFiles(path) }
        let first = AppUsageSocketServer(path: path) { Self.payload }
        try first.start()
        defer { first.stop() }

        let second = AppUsageSocketServer(path: path) { AppUsageSocketPayload(providers: []) }
        #expect(Self.startError(second) == .EADDRINUSE)
        second.stop()

        let received = try #require(await Self.read(path))
        #expect(received.providers.map(\.provider) == ["claude"])
    }

    @Test
    func `held owner lock keeps a paused instance's socket untouched until released`() throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeSocketFiles(path) }
        // A first instance paused between bind and listen: it holds the owner lock and a bound socket file.
        let lockFD = open(AppUsageSocketServer.ownerLockPath(forSocketPath: path), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(lockFD >= 0)
        try #require(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        let boundFD = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(boundFD) }
        var address = try #require(AppUsageSocket.socketAddress(path: path))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(boundFD, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        var before = stat()
        try #require(lstat(path, &before) == 0)

        let server = AppUsageSocketServer(path: path) { Self.payload }
        #expect(Self.startError(server) == .EADDRINUSE)
        var after = stat()
        #expect(lstat(path, &after) == 0)
        #expect(after.st_ino == before.st_ino)

        close(lockFD)
        try server.start()
        server.stop()
    }

    @Test
    func `server closes foreign peers without building or writing a payload`() async throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeSocketFiles(path) }
        let builds = PayloadBuildCounter()
        let server = AppUsageSocketServer(path: path, ownerUID: geteuid() &+ 1) {
            builds.increment()
            return Self.payload
        }
        try server.start()
        defer { server.stop() }

        #expect(await Self.receivedByteCount(path) == 0)
        #expect(builds.calls == 0)
    }

    @Test
    func `stop revokes a client still waiting for its payload`() async throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeSocketFiles(path) }
        let gate = PayloadGate()
        defer { gate.release() }
        let server = AppUsageSocketServer(path: path) {
            await gate.pass()
            return Self.payload
        }
        try server.start()
        defer { server.stop() }

        let client = Task { await Self.receivedByteCount(path) }
        try #require(await Self.waitUntil { gate.hasEntered })
        let clock = ContinuousClock()
        let stoppedAt = clock.now
        server.stop()
        // The payload is still held back, so this EOF can only come from stop().
        #expect(await client.value == 0)
        #expect(clock.now - stoppedAt < .seconds(5))

        gate.release()
        #expect(await Self.waitUntil { Self.isDrained(server) })
    }

    @Test
    func `restart does not answer a client accepted before stop`() async throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeSocketFiles(path) }
        let gate = PayloadGate()
        defer { gate.release() }
        let server = AppUsageSocketServer(path: path) {
            await gate.pass()
            return Self.payload
        }
        try server.start()
        defer { server.stop() }

        let oldClient = Task { await Self.receivedByteCount(path) }
        try #require(await Self.waitUntil { gate.hasEntered })
        server.stop()
        try server.start()
        #expect(await oldClient.value == 0)

        gate.release()
        #expect(await Self.waitUntil { Self.isDrained(server) })
        let received = try #require(await Self.read(path))
        #expect(received.providers.map(\.provider) == ["claude"])
    }

    @Test
    func `stop does not wait for a client that stopped reading`() async throws {
        try await Self.expectStopRevokesInFlightWrite(clientHalfCloses: false)
    }

    @Test
    func `stop revokes an in-flight write to a half-closed client`() async throws {
        try await Self.expectStopRevokesInFlightWrite(clientHalfCloses: true)
    }

    /// A raw client connects and never reads, so the server's >256 KB write fills the socket buffers and blocks.
    /// stop() must return promptly and cut the write off: the client then reads to EOF short of the full payload.
    private static func expectStopRevokesInFlightWrite(clientHalfCloses: Bool) async throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeSocketFiles(path) }
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: Self.updatedAt,
            resetDescription: "resets later")
        let windows = (0..<5000).map { NamedRateWindow(id: "window-\($0)", title: "Window \($0)", window: window) }
        let large = try AppUsageSocketPayload(providers: [
            #require(AppUsageSocketPayload.Provider(
                provider: .claude,
                usage: UsageSnapshot(
                    primary: window,
                    secondary: nil,
                    extraRateWindows: windows,
                    updatedAt: Self.updatedAt),
                credits: nil)),
        ])
        let fullSize = try large.encoded().count
        try #require(fullSize > 256 * 1024)
        let server = AppUsageSocketServer(path: path) { large }
        try server.start()
        defer { server.stop() }

        let clientFD = try #require(AppUsageSocket.connectedSocket(path: path, timeout: 30))
        defer { close(clientFD) }
        if clientHalfCloses {
            // Like `nc -U </dev/null`: the client is done sending before the server writes.
            try #require(shutdown(clientFD, SHUT_WR) == 0)
        }
        try #require(await Self.waitUntil { server.inFlightClientCount == 1 })
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let stoppedAt = clock.now
        server.stop()
        #expect(clock.now - stoppedAt < .seconds(1))

        // Read before the drain wait: a write surviving stop() would now deliver the full payload.
        let received = try #require(Self.readToEOF(clientFD))
        #expect(received < fullSize)
        #expect(clock.now - stoppedAt < .seconds(2))
        #expect(await Self.waitUntil { Self.isDrained(server) })
    }

    @Test
    func `wire payload carries usage numbers but no identity or free-form provider data`() throws {
        let updatedAt = Self.updatedAt
        let usage = try UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            details: [ProviderDetailSection(
                title: "SENTINEL-section",
                rows: [ProviderDetailSection.Row(label: "Workspace SENTINEL-row", value: "SENTINEL-value")])],
            openAIAPIUsage: OpenAIAPIUsageSnapshot(daily: [], updatedAt: updatedAt, projectID: "proj_SENTINEL_api"),
            codexResetCredits: CodexRateLimitResetCreditsSnapshot(
                credits: [CodexRateLimitResetCredit(
                    id: "SENTINEL-credit-id",
                    resetType: "SENTINEL-reset-type",
                    status: .available,
                    grantedAt: updatedAt,
                    expiresAt: nil,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: "SENTINEL-reset-title",
                    description: "SENTINEL-reset-description")],
                availableCount: 1,
                updatedAt: updatedAt),
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: UsageProvider.codex.instanceID,
                accountEmail: "sentinel@example.com",
                accountOrganization: "SENTINEL-org",
                loginMethod: "Admin API: proj_SENTINEL_plan",
                accountID: "SENTINEL-account-id"))
        let credits = CreditsSnapshot(
            remaining: 12.5,
            events: [CreditEvent(date: updatedAt, service: "SENTINEL-service", creditsUsed: 1)],
            updatedAt: updatedAt,
            codexCreditLimit: CodexCreditLimitSnapshot(
                title: "Monthly credit limit",
                used: 1,
                limit: 10,
                remainingPercent: 90,
                resetsAt: nil,
                updatedAt: updatedAt))
        let payload = try AppUsageSocketPayload(providers: [
            #require(AppUsageSocketPayload.Provider(provider: .codex, usage: usage, credits: credits)),
        ])

        let data = try payload.encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.lowercased().contains("sentinel"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((root["providers"] as? [[String: Any]])?.first)
        let encodedUsage = try #require(entry["usage"] as? [String: Any])
        #expect((encodedUsage["primary"] as? [String: Any])?["usedPercent"] as? Double == 42)
        #expect(encodedUsage["updatedAt"] != nil)
        #expect((entry["credits"] as? [String: Any])?["remaining"] as? Double == 12.5)
        let decoded = try #require(try AppUsageSocketPayload.decoded(from: data).provider(.codex))
        #expect(decoded.usage.updatedAt == updatedAt)
        #expect(decoded.credits?.displayRemaining == 9)
    }

    @Test
    func `wire payload keeps Amp allowance rows but not workspace names`() throws {
        let updatedAt = Self.updatedAt
        let usage = AmpUsageSnapshot(
            freeQuota: nil,
            freeUsed: nil,
            hourlyReplenishment: nil,
            windowHours: nil,
            individualCredits: 3,
            workspaceBalances: [AmpWorkspaceBalance(name: "SENTINEL-workspace", remaining: 7)],
            accountEmail: "sentinel@example.com",
            accountOrganization: "SENTINEL-org",
            updatedAt: updatedAt,
            subscription: AmpSubscriptionUsage(
                plan: "SENTINEL-plan",
                otherUsedPercent: 30,
                orbUsedPercent: nil,
                resetsAt: updatedAt.addingTimeInterval(86400),
                resetDescription: "resets monthly",
                agentRemaining: 12)).toUsageSnapshot(now: updatedAt)
        try #require(AmpProviderDescriptor.primaryLabel(snapshot: usage) == "Agent usage")
        let payload = try AppUsageSocketPayload(providers: [
            #require(AppUsageSocketPayload.Provider(provider: .amp, usage: usage, credits: nil)),
        ])

        let data = try payload.encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.lowercased().contains("sentinel"))
        let decoded = try #require(try AppUsageSocketPayload.decoded(from: data).provider(.amp))
        #expect(decoded.usage.details.map(\.title) == [AmpUsageSnapshot.monthlyAllowancesSectionTitle])
        #expect(AmpProviderDescriptor.primaryLabel(snapshot: decoded.usage) == "Agent usage")
        #expect(decoded.usage.primary?.usedPercent == 30)
    }

    @Test
    func `providers without usage figures are not published`() throws {
        let detailsOnly = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(
                title: "Billing",
                rows: [ProviderDetailSection.Row(label: "Plan", value: "Pro")])],
            updatedAt: Self.updatedAt)

        #expect(AppUsageSocketPayload.Provider(provider: .coderabbit, usage: detailsOnly, credits: nil) == nil)
    }

    @Test
    func `client returns nil when no app is listening`() async {
        #expect(await Self.read(Self.temporarySocketPath()) == nil)
    }

    private static func startError(_ server: AppUsageSocketServer) -> POSIXErrorCode? {
        do {
            try server.start()
            return nil
        } catch let error as POSIXError {
            return error.code
        } catch {
            return nil
        }
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

    /// Bytes a raw client receives before the server closes the connection; nil if it cannot connect or read.
    private static func receivedByteCount(_ path: String) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard let fd = AppUsageSocket.connectedSocket(path: path, timeout: 30) else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { close(fd) }
                continuation.resume(returning: Self.readToEOF(fd))
            }
        }
    }

    /// Bytes read from `fd` until EOF; nil on a read error (including the 30s receive timeout).
    private static func readToEOF(_ fd: Int32) -> Int? {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                total += count
            } else if count == 0 {
                return total
            } else if errno != EINTR {
                return nil
            }
        }
    }

    /// Polls `condition` for up to 5 seconds so a broken expectation fails instead of hanging the suite.
    private static func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Revoked clients are still closed by the server's queue after their payload resolves or their write fails.
    private static func isDrained(_ server: AppUsageSocketServer) -> Bool {
        server.pendingClientCount == 0 && server.inFlightClientCount == 0
    }

    /// Unix socket paths must fit `sun_path` (104 bytes), so keep the name short.
    private static func temporarySocketPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cbs-\(UUID().uuidString.prefix(8)).sock")
    }

    private static func removeSocketFiles(_ path: String) {
        unlink(path)
        unlink(AppUsageSocketServer.ownerLockPath(forSocketPath: path))
    }
}

private final class PayloadBuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var calls: Int {
        self.lock.withLock { self.value }
    }

    func increment() {
        self.lock.withLock { self.value += 1 }
    }
}

/// Holds the first payload build until `release()`; later builds pass straight through.
private final class PayloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var entered = false
    private var isReleased = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    var hasEntered: Bool {
        self.lock.withLock { self.entered }
    }

    func pass() async {
        let isFirst = self.lock.withLock { () -> Bool in
            self.calls += 1
            return self.calls == 1
        }
        guard isFirst else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = self.lock.withLock { () -> Bool in
                self.entered = true
                if self.isReleased {
                    return true
                }
                self.releaseWaiter = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func release() {
        let waiter = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
            self.isReleased = true
            let waiter = self.releaseWaiter
            self.releaseWaiter = nil
            return waiter
        }
        waiter?.resume()
    }
}
