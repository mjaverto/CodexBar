import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreCLIUsageCacheTests {
    @Test
    func `opted in store writes default account providers with extra rows and no identity`() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        let store = Self.makeStore(shareUsage: true, cacheURL: url)
        store._setSnapshotForTesting(Self.usage(), provider: .claude)
        store._setSnapshotForTesting(Self.usage(), provider: .zai)

        store.persistCLIUsageCache()
        await store.cliUsageCachePersistTask?.value

        let cache = try #require(CLIUsageCache.load(from: url))
        #expect(cache.entries.map(\.provider) == ["claude"])
        let usage = try #require(cache.entries.first?.usage)
        #expect(usage.primary?.usedPercent == 42)
        #expect(usage.extraRateWindows?.map(\.id) == ["opus"])
        #expect(usage.identity == nil)
        #expect(usage.updatedAt == Self.usage().updatedAt)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("person@example.com"))
    }

    @Test
    func `providers using a selected token account are not cached`() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        let store = Self.makeStore(shareUsage: true, cacheURL: url)
        store.settings.addTokenAccount(provider: .claude, label: "Work", token: "Bearer sk-ant-oat-work-token")
        store._setSnapshotForTesting(Self.usage(), provider: .claude)

        store.persistCLIUsageCache()
        await store.cliUsageCachePersistTask?.value

        #expect(try #require(CLIUsageCache.load(from: url)).entries.isEmpty)
    }

    @Test
    func `flag off writes nothing and withdraws an earlier cache`() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try CLIUsageCache.write(
            CLIUsageCache(entries: [CLIUsageCache.Entry(provider: .claude, usage: Self.usage())].compactMap(\.self)),
            to: url)
        let store = Self.makeStore(shareUsage: false, cacheURL: url)
        store._setSnapshotForTesting(Self.usage(), provider: .claude)

        store.persistCLIUsageCache()
        await store.cliUsageCachePersistTask?.value

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreCLIUsageCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeStore(shareUsage: Bool, cacheURL: URL) -> UsageStore {
        var config = testConfigWithAllProvidersDisabled()
        config.shareUsageWithCLI = shareUsage
        let settings = testSettingsStore(
            suiteName: "UsageStoreCLIUsageCacheTests",
            userDefaults: InMemoryUserDefaults(),
            config: config)
        enableTestProviders([.claude], settings: settings)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: "/synthetic", fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            cliUsageCacheURL: cacheURL)
    }

    private static func usage() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "opus",
                title: "Opus",
                window: RateWindow(usedPercent: 63, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: "Example Org",
                loginMethod: "Max"))
    }
}
