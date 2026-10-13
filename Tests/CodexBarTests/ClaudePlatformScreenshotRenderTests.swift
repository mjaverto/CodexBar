import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in synthetic Claude Platform cards for PR proof, with data that mirrors the `ClaudePlatformPluginTests`
/// fixture values; keep in sync.
///
///     CODEXBAR_CLAUDEPLATFORM_SCREENSHOT_DIR=/tmp/cards swift test --filter ClaudePlatformScreenshotRenderTests
@MainActor
final class ClaudePlatformScreenshotRenderTests: XCTestCase {
    /// 2026-10-13T00:00:00Z
    private static let now = Date(timeIntervalSince1970: 1_791_849_600)
    private nonisolated static let organizations = #"""
    [{"uuid":"11111111-1111-4111-8111-111111111111","name":"Synthetic Chat Organization","capabilities":["chat"]},
     {"uuid":"22222222-2222-4222-8222-222222222222","name":"Synthetic API Org","capabilities":["api"]}]
    """#
    private nonisolated static let credits = #"""
    {"amount":18725,"currency":"USD","balance":{"money":null,"credits":{"amount_minor":18725,"exponent":2}},
     "tranches":[{"remaining_amount_minor_units":6250,"granted_amount_minor_units":10000,"currency":"USD",
       "expires_at":"2027-05-01T00:00:00Z","program_id":"api_credits","name":null}],
     "promo_tranches":[{"remaining_amount_minor_units":12475,"granted_amount_minor_units":20000,"currency":"USD",
       "expires_at":"2026-10-28T00:00:00Z","program_id":"subscription_api_credit","name":"API credit (Max 20x)"}]}
    """#
    private nonisolated static let spend = #"{"amount":4321,"resets_at":"2026-11-01T00:00:00Z"}"#

    func test_renderSyntheticCreditCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDEPLATFORM_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDEPLATFORM_SCREENSHOT_DIR to render synthetic Claude Platform cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let snapshot = try await Self.fetch()
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, showUsed) in [("remaining-left", false), ("remaining-used", true)] {
                let model = try Self.model(snapshot, showUsed: showUsed)
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("claudeplatform-\(name).png"))
            }
        }
    }

    private static func fetch() async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime(
            "claudeplatform",
            engine: .quickJS,
            transport: ProviderHTTPTransportHandler { request in
                let path = request.url?.path ?? ""
                let body = if path.hasSuffix("/prepaid/credits") {
                    Self.credits
                } else if path.hasSuffix("/current_spend") {
                    Self.spend
                } else {
                    Self.organizations
                }
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            now: Self.now,
            timeZone: TimeZone(identifier: "UTC") ?? .gmt,
            cookieSessionResolver: { _, _ in
                ProviderPluginCookieSession(
                    header: "sessionKey=sk-ant-sid01-synthetic",
                    source: "Synthetic",
                    origin: "https://platform.claude.com")
            },
            cookieSessionValidator: { _, _ in })
    }

    private static func model(_ snapshot: UsageSnapshot, showUsed: Bool) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .claudeplatform,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.claudeplatform]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .claudeplatform)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: self.now))
    }
}
