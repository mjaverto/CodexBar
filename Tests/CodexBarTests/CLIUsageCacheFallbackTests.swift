import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIUsageCacheFallbackTests {
    private static let provider = UsageProvider.zai

    @Test
    func `locked keychain failure renders the cached usage as source codexbar app with its age`() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try Self.command(arguments: ["--json"], cacheRoot: root, lockedKeychainObserved: true)

        let output = try await Self.fetch(command: command)

        #expect(output.exitCode == .success)
        let data = try JSONEncoder().encode(output.payload)
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry["provider"] as? String == Self.provider.rawValue)
        #expect(entry["source"] as? String == "codexbar-app")
        #expect((entry["ageSeconds"] as? Int ?? 0) >= 60)
        #expect(entry["error"] == nil)
        let usage = try #require(entry["usage"] as? [String: Any])
        #expect((usage["extraRateWindows"] as? [[String: Any]])?.count == 1)
    }

    @Test
    func `text output says the usage was cached by the app`() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try Self.command(arguments: [], cacheRoot: root, lockedKeychainObserved: true)

        let output = try await Self.fetch(command: command)

        let text = try #require(output.sections.first)
        #expect(text.contains("(codexbar-app)"))
        #expect(text.contains("Cached by the CodexBar app"))
    }

    @Test
    func `other failures keep the local error even with a fresh cache`() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try Self.command(arguments: ["--json"], cacheRoot: root, lockedKeychainObserved: false)

        let output = try await Self.fetch(command: command)

        #expect(output.exitCode != .success)
        let data = try JSONEncoder().encode(output.payload)
        let entry = try #require(try (JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        #expect(entry["source"] as? String != "codexbar-app")
        #expect(entry["error"] != nil)
        #expect(entry["usage"] == nil)
    }

    @Test
    func `explicit source keeps the local failure`() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try Self.command(
            arguments: ["--json", "--source", "api"],
            cacheRoot: root,
            lockedKeychainObserved: true)

        let output = try await Self.fetch(command: command)

        #expect(output.exitCode != .success)
        #expect(output.payload.first?.source != "codexbar-app")
    }

    @Test
    func `without the config flag no reader is installed`() throws {
        let command = try Self.command(arguments: ["--json"], cacheRoot: nil, lockedKeychainObserved: true)

        #expect(command.withUsageCacheFallback(config: CodexBarConfig(providers: [])).usageCacheFallback == nil)
    }

    private static func fetch(command: UsageCommandContext) async throws -> UsageCommandOutput {
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: []),
            verbose: false,
            baseEnvironment: [:])
        return await CodexBarCLI.fetchUsageOutputs(
            provider: Self.provider,
            status: nil,
            tokenContext: context,
            command: command)
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIUsageCacheFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Context whose cache reader sees a synthetic non-GUI session and a synthetic keychain-lock observation.
    private static func command(
        arguments: [String],
        cacheRoot: URL?,
        lockedKeychainObserved: Bool) throws -> UsageCommandContext
    {
        let values = try Program(descriptors: CodexBarCLI.commandDescriptors())
            .resolve(argv: ["usage", "--no-color"] + arguments).parsedValues
        var command = try CLIUsageFetchSetup(
            values: values,
            providers: [Self.provider],
            output: CLIOutputPreferences.from(values: values, allowsToon: true)).command
        guard let cacheRoot else { return command }
        let url = cacheRoot.appendingPathComponent("cache/usage.json")
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "opus",
                title: "Opus",
                window: RateWindow(usedPercent: 63, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))],
            updatedAt: Date().addingTimeInterval(-90))
        try CLIUsageCache.write(
            CLIUsageCache(entries: [CLIUsageCache.Entry(provider: Self.provider, usage: usage)].compactMap(\.self)),
            to: url)
        command.usageCacheFallback = CLIUsageCache.fallbackReader(
            url: url,
            hasGraphicSession: { false },
            lockedKeychainObserved: { lockedKeychainObserved })
        return command
    }
}
