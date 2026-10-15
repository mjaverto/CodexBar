import Foundation
import Testing
#if os(macOS)
import Security
#endif
@testable import CodexBarCore

struct CLIUsageCacheTests {
    private static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let now = fetchedAt.addingTimeInterval(90)

    @Test
    func `balances are stripped and future dated or fully expired entries are not served`() throws {
        let cost = ProviderCostSnapshot(
            used: 1,
            limit: 10,
            currencyCode: "USD",
            balance: 5,
            balanceUpdatedAt: Self.fetchedAt,
            balanceIsWorkspace: true,
            updatedAt: Self.fetchedAt)
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: Self.fetchedAt.addingTimeInterval(300),
                resetDescription: nil),
            secondary: nil,
            providerCost: cost,
            updatedAt: Self.fetchedAt)
        let cache = CLIUsageCache(entries: [CLIUsageCache.Entry(provider: .codex, usage: usage)].compactMap(\.self))

        let served = try #require(cache.hit(for: .codex, now: Self.now)?.entry.usage.providerCost)
        #expect(served.used == 1)
        #expect(served.balance == nil)
        #expect(served.balanceUpdatedAt == nil)
        #expect(served.balanceIsWorkspace == nil)
        // Future dated (beyond the clock-skew tolerance).
        #expect(cache.hit(for: .codex, now: Self.fetchedAt.addingTimeInterval(-120)) == nil)
        // The only rate window has already reset.
        #expect(cache.hit(for: .codex, now: Self.fetchedAt.addingTimeInterval(301)) == nil)
    }

    @Test
    func `expired windows are dropped while live ones are kept`() throws {
        let expired = RateWindow(
            usedPercent: 90,
            windowMinutes: 300,
            resetsAt: Self.fetchedAt.addingTimeInterval(10),
            resetDescription: nil)
        let live = RateWindow(
            usedPercent: 20,
            windowMinutes: 10080,
            resetsAt: Self.fetchedAt.addingTimeInterval(9999),
            resetDescription: nil)
        let usage = UsageSnapshot(primary: expired, secondary: live, updatedAt: Self.fetchedAt)
        let cache = CLIUsageCache(entries: [CLIUsageCache.Entry(provider: .claude, usage: usage)].compactMap(\.self))

        let served = try #require(cache.hit(for: .claude, now: Self.now)?.entry.usage)
        #expect(served.primary == nil)
        #expect(served.secondary?.usedPercent == 20)
    }

    @Test
    func `round trip keeps extra quota rows and drops identity`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        let usage = try Self.leakyUsage()
        let entry = try #require(CLIUsageCache.Entry(provider: .claude, usage: usage))

        try CLIUsageCache.write(CLIUsageCache(entries: [entry]), to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        for forbidden in Self.secrets + ["accountEmail", "projectID", "openAIAPIUsage", "throughput", "details"] {
            #expect(!raw.contains(forbidden))
        }
        let hit = try #require(CLIUsageCache.load(from: url)?.hit(for: .claude, now: Self.now))
        #expect(hit.ageSeconds == 90)
        #expect(hit.entry.usage.primary?.usedPercent == 42)
        #expect(hit.entry.usage.extraRateWindows?.map(\.id) == ["opus"])
        #expect(hit.entry.usage.extraRateWindows?.first?.window.usedPercent == 63)
        #expect(hit.entry.usage.identity == nil)
    }

    @Test
    func `reading re-projects a file that carries identity or provider blobs`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = try String(bytes: encoder.encode(Self.leakyUsage()), encoding: .utf8) ?? ""
        #expect(snapshot.contains("proj-secret"))
        try Self.writeRaw(#"{"entries":[{"provider":"claude","usage":\#(snapshot)}]}"#, to: url)

        let usage = try #require(CLIUsageCache.load(from: url)?.entries.first?.usage)

        #expect(usage.primary?.usedPercent == 42)
        #expect(usage.identity == nil)
        #expect(usage.throughput == nil)
        #expect(usage.openAIAPIUsage == nil)
        #expect(usage.details.isEmpty)
        let reencoded = try String(bytes: encoder.encode(usage), encoding: .utf8) ?? ""
        for secret in Self.secrets {
            #expect(!reencoded.contains(secret))
        }
    }

    @Test
    func `write creates a private file inside a private directory`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")

        try CLIUsageCache.write(Self.cache(), to: url)
        // A rewrite replaces the file atomically and keeps the modes.
        try CLIUsageCache.write(Self.cache(), to: url)

        #expect(try Self.mode(of: url) == 0o600)
        #expect(try Self.mode(of: url.deletingLastPathComponent()) == 0o700)
    }

    @Test
    func `write refuses a symlinked or foreign directory`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(throws: (any Error).self) {
            try CLIUsageCache.write(Self.cache(), to: link.appendingPathComponent("usage.json"))
        }
        #expect(throws: (any Error).self) {
            try CLIUsageCache.write(
                Self.cache(),
                to: real.appendingPathComponent("usage.json"),
                ownerUID: geteuid() &+ 1)
        }
    }

    @Test
    func `entries without usage figures are not cached`() {
        let usage = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Self.fetchedAt)
        #expect(CLIUsageCache.Entry(provider: .claude, usage: usage) == nil)
    }

    @Test
    func `reads a hand written cache file`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try Self.writeRaw(
            """
            {"entries":[{"provider":"claude","usage":{
              "primary":{"usedPercent":12.5,"windowMinutes":300},"secondary":null,"tertiary":null,
              "updatedAt":"2027-01-15T08:00:00Z"}}]}
            """,
            to: url)

        let cache = try #require(CLIUsageCache.load(from: url))
        let updatedAt = try #require(cache.entries.first?.usage.updatedAt)
        let hit = try #require(cache.hit(for: .claude, now: updatedAt.addingTimeInterval(5)))
        #expect(hit.entry.usage.primary?.usedPercent == 12.5)
        #expect(hit.ageSeconds == 5)
        #expect(cache.hit(for: .codex, now: updatedAt) == nil)
    }

    @Test
    func `stale entries are ignored`() {
        let cache = Self.cache()

        #expect(cache.hit(for: .claude, now: Self.fetchedAt.addingTimeInterval(CLIUsageCache.maximumAge)) != nil)
        #expect(cache.hit(for: .claude, now: Self.fetchedAt.addingTimeInterval(CLIUsageCache.maximumAge + 1)) == nil)
    }

    @Test
    func `corrupt file is ignored`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")

        try Self.writeRaw("{not json", to: url)
        #expect(CLIUsageCache.load(from: url) == nil)
        #expect(CLIUsageCache.load(from: root.appendingPathComponent("missing/usage.json")) == nil)
    }

    @Test
    func `wrong owner is ignored`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try CLIUsageCache.write(Self.cache(), to: url)

        #expect(CLIUsageCache.load(from: url) != nil)
        #expect(CLIUsageCache.load(from: url, ownerUID: geteuid() &+ 1) == nil)
    }

    @Test
    func `group or world accessible file or directory is ignored`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        let directory = url.deletingLastPathComponent()
        try CLIUsageCache.write(Self.cache(), to: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        #expect(CLIUsageCache.load(from: url) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(CLIUsageCache.load(from: url) != nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: directory.path)
        #expect(CLIUsageCache.load(from: url) == nil)
    }

    @Test
    func `symlinked cache file is ignored`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/usage.json")
        try CLIUsageCache.write(Self.cache(), to: real)
        let link = root.appendingPathComponent("link/usage.json")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(CLIUsageCache.load(from: link) == nil)
    }

    @Test
    func `removing withdraws the cache`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try CLIUsageCache.write(Self.cache(), to: url)

        CLIUsageCache.remove(at: url)
        CLIUsageCache.remove(at: url)

        #expect(CLIUsageCache.load(from: url) == nil)
    }

    @Test
    func `graphic sessions get no fallback`() {
        let reader = CLIUsageCache.fallbackReader(
            url: URL(fileURLWithPath: "/nonexistent/usage.json"),
            hasGraphicSession: { true },
            lockedKeychainObserved: { true })

        #expect(reader == nil)
    }

    @Test
    func `fallback needs a locked keychain failure`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try CLIUsageCache.write(Self.cache(), to: url)
        let failure = NSError(domain: "provider", code: 1)

        func reader(lockedObserved: Bool) throws -> @Sendable (UsageProvider, Error) -> CLIUsageCache.Hit? {
            let reader = CLIUsageCache.fallbackReader(
                url: url,
                hasGraphicSession: { false },
                lockedKeychainObserved: { lockedObserved },
                now: { Self.now })
            return try #require(reader)
        }

        // Any other failure (bad key, network, 403): no cache, even though the keychain may be locked.
        #expect(try reader(lockedObserved: false)(.claude, failure) == nil)
        // A keychain read in this fetch failed as locked: cache.
        #expect(try reader(lockedObserved: true)(.claude, failure)?.ageSeconds == 90)
        // Provider the app never cached.
        #expect(try reader(lockedObserved: true)(.codex, failure) == nil)
        #if os(macOS)
        let locked = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))
        #expect(try reader(lockedObserved: false)(.claude, locked)?.ageSeconds == 90)
        let notFound = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound))
        #expect(try reader(lockedObserved: false)(.claude, notFound) == nil)
        let claude = ClaudeOAuthCredentialsError.keychainError(Int(errSecAuthFailed))
        #expect(try reader(lockedObserved: false)(.claude, claude)?.ageSeconds == 90)
        #endif
    }

    @Test
    func `config flag round trips and is omitted when off`() throws {
        var config = CodexBarConfig(providers: [])
        #expect(!config.shareUsageWithCLI)
        let off = try config.encodedData()
        #expect(try !#require(String(bytes: off, encoding: .utf8)).contains("shareUsageWithCLI"))
        #expect(try !CodexBarConfig.decode(from: off).shareUsageWithCLI)

        config.shareUsageWithCLI = true
        let on = try config.encodedData()
        #expect(try #require(String(bytes: on, encoding: .utf8)).contains("\"shareUsageWithCLI\""))
        #expect(try CodexBarConfig.decode(from: on).shareUsageWithCLI)
    }

    private static let secrets = ["person@example.com", "Example Org", "Max", "proj-secret", "Secret Detail Row"]

    /// A snapshot carrying identity, provider blobs and detail rows next to the figures that should survive.
    private static func leakyUsage() throws -> UsageSnapshot {
        try UsageSnapshot(
            primary: self.window(42),
            secondary: self.window(7),
            extraRateWindows: [NamedRateWindow(id: "opus", title: "Opus", window: self.window(63))],
            details: [ProviderDetailSection.makeSection(rows: [
                ProviderDetailSection.Row(label: "Secret Detail Row", value: "Example Org"),
            ])],
            throughput: ProviderThroughputSnapshot(
                minutes: [],
                frontier: nil,
                latestTokensPerMinute: nil,
                peakTokensPerMinute: 0,
                peakAt: nil,
                fiveMinuteAverageTokensPerMinute: 0,
                models: [],
                windowMinutes: 5,
                fetchedAt: self.fetchedAt,
                projectID: "proj-secret"),
            openAIAPIUsage: OpenAIAPIUsageSnapshot(daily: [], updatedAt: self.fetchedAt, projectID: "proj-secret"),
            updatedAt: self.fetchedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: "Example Org",
                loginMethod: "Max"))
    }

    private static func cache() -> CLIUsageCache {
        let usage = UsageSnapshot(primary: Self.window(42), secondary: nil, updatedAt: Self.fetchedAt)
        return CLIUsageCache(entries: [CLIUsageCache.Entry(provider: .claude, usage: usage)].compactMap(\.self))
    }

    private static func window(_ used: Double) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIUsageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeRaw(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path)
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600])
    }

    private static func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }
}
