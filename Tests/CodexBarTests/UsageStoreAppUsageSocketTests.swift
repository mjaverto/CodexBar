import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreAppUsageSocketTests {
    @Test
    func `payload carries only enabled providers with fresh usage`() {
        let store = Self.makeStore()
        store._setSnapshotForTesting(Self.usage(provider: .claude), provider: .claude)
        store._setSnapshotForTesting(Self.usage(provider: .copilot), provider: .copilot)
        store._setErrorForTesting("Session expired", provider: .copilot)
        store._setSnapshotForTesting(Self.usage(provider: .zai), provider: .zai)

        let payload = store.appUsageSocketPayload()

        #expect(payload.version == AppUsageSocketPayload.currentVersion)
        #expect(payload.providers.map(\.provider) == ["claude"])
        #expect(payload.provider(.claude)?.usage.primary?.usedPercent == 42)
        #expect(payload.provider(.claude)?.credits == nil)
    }

    @Test
    func `payload strips account identity but keeps the plan`() throws {
        let store = Self.makeStore()
        store.settings.hidePersonalInfo = false
        store._setSnapshotForTesting(Self.usage(provider: .claude), provider: .claude)

        let usage = try #require(store.appUsageSocketPayload().provider(.claude)?.usage)

        #expect(usage.loginMethod(for: .claude) == "Max")
        #expect(usage.accountEmail(for: .claude) == nil)
        #expect(usage.accountOrganization(for: .claude) == nil)
        #expect(usage.identity?.accountID == nil)
    }

    private static func makeStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStoreAppUsageSocketTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        enableTestProviders([.claude, .copilot, .cursor], settings: settings)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: "/synthetic", fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func usage(provider: UsageProvider) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: "fixture@example.com",
                accountOrganization: "Fixture Org",
                loginMethod: "Max",
                accountID: "acct-fixture"))
    }
}
