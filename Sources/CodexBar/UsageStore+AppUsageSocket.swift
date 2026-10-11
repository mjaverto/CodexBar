import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Latest usage for enabled providers, published to same-user CLI processes over `AppUsageSocket`.
    /// Stale providers are skipped so the CLI keeps its local error instead of reporting old numbers; account
    /// identity is always reduced to the plan.
    func appUsageSocketPayload() -> AppUsageSocketPayload {
        let providers = self.enabledFirstPartyProvidersForDisplay().compactMap { provider in
            guard !self.isStale(provider: provider),
                  let snapshot = self.presentationSnapshot(for: provider)
            else { return nil as AppUsageSocketPayload.Provider? }
            var usage = snapshot.scoped(to: provider)
            if let identity = usage.identity {
                usage = usage.withIdentity(ProviderIdentitySnapshot(
                    providerID: identity.providerID,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: identity.loginMethod,
                    accountID: nil))
            }
            return AppUsageSocketPayload.Provider(
                provider: provider,
                usage: usage,
                // Provider-specific by design: `UsageStore.credits` holds the Codex credits snapshot.
                credits: provider == .codex ? self.credits : nil)
        }
        return AppUsageSocketPayload(providers: providers)
    }
}
