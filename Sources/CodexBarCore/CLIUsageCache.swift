#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
#if os(macOS)
import Security
#endif

/// Private same-user usage cache the menu bar app writes after each refresh (opt-in via
/// `CodexBarConfig.shareUsageWithCLI`). SSH sessions cannot unlock the login keychain, so `codexbar usage` there can
/// fail for keychain-backed providers while the app holds fresh numbers; the CLI reads this file only after such a
/// failure. Carries usage figures only: no credentials and no account identity fields (email, organization,
/// account ID, plan).
public struct CLIUsageCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        /// `UsageProvider.rawValue`; a string so providers unknown to an older CLI don't break decoding.
        public let provider: String
        /// Allowlisted figures only; `usage.updatedAt` is this provider's fetch time.
        public let usage: UsageSnapshot

        /// Nil when nothing numeric is left to show.
        public init?(provider: UsageProvider, usage: UsageSnapshot) {
            guard usage.hasRateLimitWindows || usage.providerCost != nil else { return nil }
            self.provider = provider.rawValue
            self.usage = Self.figures(usage)
        }

        /// Projects again on read, so a hand-edited or older file cannot carry other fields into CLI output.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.provider = try container.decode(String.self, forKey: .provider)
            self.usage = try Self.figures(container.decode(UsageSnapshot.self, forKey: .usage))
        }

        /// Built field by field: new `UsageSnapshot` fields (provider blobs, details, identity) stay out until listed.
        /// Codex credit balances are not cached: only the spend figures of `providerCost` are kept.
        private static func figures(_ usage: UsageSnapshot) -> UsageSnapshot {
            UsageSnapshot(
                primary: usage.primary,
                secondary: usage.secondary,
                tertiary: usage.tertiary,
                extraRateWindows: usage.extraRateWindows,
                providerCost: usage.providerCost.map(self.withoutBalance),
                updatedAt: usage.updatedAt,
                dataConfidence: usage.dataConfidence)
        }

        private static func withoutBalance(_ cost: ProviderCostSnapshot) -> ProviderCostSnapshot {
            ProviderCostSnapshot(
                used: cost.used,
                limit: cost.limit,
                currencyCode: cost.currencyCode,
                period: cost.period,
                resetsAt: cost.resetsAt,
                nextRegenAmount: cost.nextRegenAmount,
                personalUsed: cost.personalUsed,
                updatedAt: cost.updatedAt)
        }

        /// Already-projected figures (the read-time freshness filter), without re-running the projection.
        fileprivate init(provider: String, filtered usage: UsageSnapshot) {
            self.provider = provider
            self.usage = usage
        }
    }

    /// An entry served to the CLI, with its age at read time.
    public struct Hit: Sendable {
        public let entry: Entry
        public let ageSeconds: Int
    }

    /// Older entries are ignored so the CLI reports its own error instead of misleading numbers.
    public static let maximumAge: TimeInterval = 3600
    /// Entries dated further ahead than this (clock skew) are not served.
    static let futureTolerance: TimeInterval = 60
    /// The cache is tiny; anything bigger is not ours.
    static let maximumFileSize = 1 << 20

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("CodexBar/CLIUsageCache", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)
    }

    // MARK: Write (app)

    /// Atomic write of a `0600` file inside a `0700` directory.
    public static func write(
        _ cache: CLIUsageCache,
        to url: URL = defaultURL(),
        fileManager: FileManager = .default,
        ownerUID: uid_t = geteuid()) throws
    {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Never chmod a symlink or a directory someone else owns.
        guard Self.mode(of: directory, type: .typeDirectory, fileManager, ownerUID) != nil else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try CredentialFileWriter.writePrivate(encoder.encode(cache), to: url)
    }

    /// Withdraws previously shared usage when the option is turned off.
    public static func remove(at url: URL = defaultURL(), fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: Read (CLI)

    /// Nil unless the file is a private regular file owned by `ownerUID` in a private directory, and decodes.
    public static func load(
        from url: URL = defaultURL(),
        fileManager: FileManager = .default,
        ownerUID: uid_t = geteuid()) -> CLIUsageCache?
    {
        guard let directoryMode = mode(
            of: url.deletingLastPathComponent(),
            type: .typeDirectory,
            fileManager,
            ownerUID),
            directoryMode & 0o077 == 0
        else { return nil }
        // O_NOFOLLOW + fstat check the very file that gets read.
        // O_NONBLOCK keeps a FIFO from hanging the open; the S_IFREG check then rejects it.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == ownerUID,
              metadata.st_mode & 0o077 == 0,
              let data = try? handle.read(upToCount: Self.maximumFileSize)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CLIUsageCache.self, from: data)
    }

    /// Permission bits when `url` itself (not a symlink target) is `type` and owned by `ownerUID`.
    private static func mode(of url: URL, type: FileAttributeType, _ fileManager: FileManager, _ ownerUID: uid_t)
        -> UInt16?
    {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == ownerUID
        else { return nil }
        return (attributes[.posixPermissions] as? NSNumber)?.uint16Value
    }

    public func hit(for provider: UsageProvider, now: Date = Date()) -> Hit? {
        guard let entry = self.entries.first(where: { $0.provider == provider.rawValue }) else { return nil }
        let age = now.timeIntervalSince(entry.usage.updatedAt)
        // Future-dated entries (clock skew or tampering) are not trusted.
        guard age <= Self.maximumAge, age >= -Self.futureTolerance else { return nil }
        let source = entry.usage
        let hadWindows = source.hasRateLimitWindows
        func live(_ window: RateWindow?) -> RateWindow? {
            guard let window, window.resetsAt.map({ $0 >= now }) ?? true else { return nil }
            return window
        }
        let cost = source.providerCost.flatMap {
            now.timeIntervalSince($0.updatedAt) <= Self.maximumAge ? $0 : nil
        }
        let usage = UsageSnapshot(
            primary: live(source.primary),
            secondary: live(source.secondary),
            tertiary: live(source.tertiary),
            extraRateWindows: source.extraRateWindows?.filter { live($0.window) != nil },
            providerCost: cost,
            updatedAt: source.updatedAt,
            dataConfidence: source.dataConfidence)
        // Every window already reset: the numbers would mislead, so report the CLI's own error instead.
        guard hadWindows ? usage.hasRateLimitWindows : usage.providerCost != nil else { return nil }
        return Hit(entry: Entry(provider: entry.provider, filtered: usage), ageSeconds: Int(max(0, age)))
    }

    /// Serves cached usage after a failed fetch. Nil (no fallback) when the caller has a GUI session, so local
    /// behavior there is unchanged. Applies only when this fetch itself ran into a locked keychain: the error carries
    /// a locked-keychain status, or `lockedKeychainObserved` reports a Keychain read that failed that way since the
    /// CLI reset `KeychainLockWitness` for this provider.
    public static func fallbackReader(
        url: URL = defaultURL(),
        fileManager: FileManager = .default,
        hasGraphicSession: () -> Bool = CLIUsageCache.callerHasGraphicSession,
        lockedKeychainObserved: @escaping @Sendable () -> Bool = CLIUsageCache.keychainLockObserved,
        now: @escaping @Sendable () -> Date = { Date() })
        -> (@Sendable (UsageProvider, Error) -> Hit?)?
    {
        guard !hasGraphicSession() else { return nil }
        // FileManager is documented thread-safe for these one-shot reads.
        nonisolated(unsafe) let reader = fileManager
        return { provider, error in
            guard Self.isLockedKeychainError(error) || lockedKeychainObserved() else { return nil }
            return Self.load(from: url, fileManager: reader)?.hit(for: provider, now: now())
        }
    }

    // MARK: Locked-keychain detection

    #if os(macOS)
    /// Unknown session state counts as a GUI session so the existing local-only behavior stays.
    public static func callerHasGraphicSession() -> Bool {
        var attributes = SessionAttributeBits()
        guard SessionGetInfo(callerSecuritySession, nil, &attributes) == errSecSuccess else { return true }
        return attributes.contains(.sessionHasGraphicAccess)
    }

    public static func keychainLockObserved() -> Bool {
        KeychainLockWitness.didObserveLockedKeychain
    }

    static func isLockedKeychainError(_ error: Error) -> Bool {
        let status: Int
        // Provider-specific by design: Claude OAuth surfaces keychain statuses through its own error type.
        if case let ClaudeOAuthCredentialsError.keychainError(code) = error {
            status = code
        } else if (error as NSError).domain == NSOSStatusErrorDomain {
            status = (error as NSError).code
        } else {
            return false
        }
        return status == Int(errSecInteractionNotAllowed) || status == Int(errSecAuthFailed)
    }
    #else
    public static func callerHasGraphicSession() -> Bool {
        true
    }

    public static func keychainLockObserved() -> Bool {
        false
    }

    static func isLockedKeychainError(_: Error) -> Bool {
        false
    }
    #endif
}
