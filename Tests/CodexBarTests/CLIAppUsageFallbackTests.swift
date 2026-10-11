import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIAppUsageFallbackTests {
    private static let appPayload = AppUsageSocketPayload(providers: [
        AppUsageSocketPayload.Provider(
            provider: .claude,
            usage: UsageSnapshot(
                primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            credits: nil),
    ])

    @Test
    func `failed default fetch renders the app's usage as source codexbar app`() throws {
        let command = try Self.command(arguments: ["--json"])

        let output = try #require(Self.fallbackOutput(command: command))

        #expect(output.exitCode == .success)
        let data = try JSONEncoder().encode(output.payload)
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry["provider"] as? String == "claude")
        #expect(entry["source"] as? String == "codexbar-app")
        #expect(entry["version"] == nil)
        #expect(entry["usage"] is [String: Any])
        #expect(entry["error"] == nil)
    }

    @Test
    func `text output says the usage came from the running app`() throws {
        let command = try Self.command(arguments: [])

        let output = try #require(Self.fallbackOutput(command: command))

        let text = try #require(output.sections.first)
        #expect(text.contains("(codexbar-app)"))
        #expect(text.contains("From the running CodexBar app."))
    }

    @Test
    func `explicit source keeps the local failure`() throws {
        let command = try Self.command(arguments: ["--json", "--source", "oauth"])

        #expect(Self.fallbackOutput(command: command) == nil)
    }

    @Test
    func `selected accounts keep the local failure`() throws {
        let command = try Self.command(arguments: ["--json"])

        #expect(Self.fallbackOutput(command: command, isDefaultAccount: false) == nil)
    }

    @Test
    func `provider missing from the app keeps the local failure`() throws {
        let command = try Self.command(arguments: ["--json"])

        #expect(Self.fallbackOutput(command: command, provider: .codex) == nil)
    }

    private static func fallbackOutput(
        command: UsageCommandContext,
        provider: UsageProvider = .claude,
        isDefaultAccount: Bool = true) -> UsageCommandOutput?
    {
        CodexBarCLI.appUsageFallbackOutput(
            provider: provider,
            isDefaultAccount: isDefaultAccount,
            status: nil,
            effectiveSourceMode: command.sourceModeOverride ?? .auto,
            command: command)
    }

    private static func command(arguments: [String]) throws -> UsageCommandContext {
        let values = try Program(descriptors: CodexBarCLI.commandDescriptors())
            .resolve(argv: ["usage", "--no-color"] + arguments).parsedValues
        var command = try CLIUsageFetchSetup(
            values: values,
            providers: [.claude],
            output: CLIOutputPreferences.from(values: values, allowsToon: true)).command
        command.appUsageFallback = { Self.appPayload.provider($0) }
        return command
    }
}
