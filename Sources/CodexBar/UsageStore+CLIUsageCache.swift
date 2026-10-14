import CodexBarCore
import Foundation

extension UsageStore {
    /// Publishes (or, when the option is off, withdraws) the private usage cache SSH `codexbar usage` runs fall back
    /// to. Built from the store's own snapshots, before any widget display filtering, so extra quota rows and
    /// per-provider fetch times survive. The file I/O runs off the main actor, in order.
    func persistCLIUsageCache() {
        // Tests must never touch the real Application Support directory; they opt in with an injected URL.
        guard !SettingsStore.isRunningTests || self.cliUsageCacheURL != nil else { return }
        let url = self.cliUsageCacheURL ?? CLIUsageCache.defaultURL()
        let entries: [CLIUsageCache.Entry]? = self.settings.config.shareUsageWithCLI
            ? self.enabledFirstPartyProvidersForDisplay().compactMap { provider in
                // Only the default/system account matches what the CLI fetches itself.
                guard self.settings.effectiveSelectedTokenAccount(for: provider) == nil,
                      provider != .codex || self.settings.codexActiveSource == .liveSystem,
                      let snapshot = self.presentationSnapshot(for: provider)
                else { return nil }
                return CLIUsageCache.Entry(provider: provider, usage: snapshot)
            }
            : nil
        let previous = self.cliUsageCachePersistTask
        self.cliUsageCachePersistTask = Task.detached(priority: .utility) {
            _ = await previous?.value
            guard let entries else { return CLIUsageCache.remove(at: url) }
            do {
                try CLIUsageCache.write(CLIUsageCache(entries: entries), to: url)
            } catch {
                CodexBarLog.logger(LogCategories.app).error(
                    "CLI usage cache write failed",
                    metadata: ["error": error.localizedDescription])
            }
        }
    }
}
