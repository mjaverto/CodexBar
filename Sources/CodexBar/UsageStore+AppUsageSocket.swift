import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Latest usage for enabled providers, published to same-user CLI processes over `AppUsageSocket`.
    /// Stale providers are skipped so the CLI keeps its local error instead of reporting old numbers;
    /// `AppUsageSocketPayload.Provider` reduces each snapshot to usage figures and drops entries without any.
    func appUsageSocketPayload() -> AppUsageSocketPayload {
        let providers = self.enabledFirstPartyProvidersForDisplay().compactMap { provider in
            guard !self.isStale(provider: provider),
                  let snapshot = self.presentationSnapshot(for: provider)
            else { return nil as AppUsageSocketPayload.Provider? }
            return AppUsageSocketPayload.Provider(
                provider: provider,
                usage: snapshot.scoped(to: provider),
                // Provider-specific by design: `UsageStore.credits` holds the Codex credits snapshot.
                credits: provider == .codex ? self.credits : nil)
        }
        return AppUsageSocketPayload(providers: providers)
    }
}
