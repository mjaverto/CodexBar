import Foundation

// MARK: - Payload

/// Usage the running menu bar app publishes for same-user CLI processes that cannot read login-keychain secrets
/// (for example `codexbar usage` over SSH). A private app-to-CLI channel whose format can change in any release.
/// Carries usage figures with their window and limit labels; never credentials, account identity, plan, or detail
/// rows (except Amp's allowance rows).
public struct AppUsageSocketPayload: Codable, Sendable {
    public struct Provider: Codable, Sendable {
        /// `UsageProvider.rawValue`; a string so providers unknown to an older CLI don't break decoding.
        public let provider: String
        public let usage: UsageSnapshot
        public let credits: CreditsSnapshot?

        /// Stores an allowlisted projection so no producer can put identity or free-form provider data on the wire:
        /// rate windows (with their labels), spend, Codex credit balance and cap, reset and renewal dates, and
        /// timestamps. Returns nil when nothing numeric is left, so the CLI keeps its local error instead.
        public init?(provider: UsageProvider, usage: UsageSnapshot, credits: CreditsSnapshot?) {
            let usage = Self.usageFigures(usage, provider: provider)
            guard usage.hasRateLimitWindows || usage.providerCost != nil || credits != nil else { return nil }
            self.provider = provider.rawValue
            self.usage = usage
            self.credits = credits.map(Self.creditFigures)
        }

        /// Built field by field so new `UsageSnapshot` fields stay off the wire until they are allowlisted here.
        private static func usageFigures(_ usage: UsageSnapshot, provider: UsageProvider) -> UsageSnapshot {
            // Provider-specific by design: Amp's window labels depend on its constant-labelled allowance rows.
            let details = provider == .amp
                ? usage.details.filter { $0.title == AmpUsageSnapshot.monthlyAllowancesSectionTitle }
                : []
            return UsageSnapshot(
                primary: usage.primary,
                secondary: usage.secondary,
                tertiary: usage.tertiary,
                extraRateWindows: usage.extraRateWindows,
                providerCost: usage.providerCost,
                details: details,
                copilotMeteredZeroCredits: usage.copilotMeteredZeroCredits,
                subscriptionExpiresAt: usage.subscriptionExpiresAt,
                subscriptionRenewsAt: usage.subscriptionRenewsAt,
                subscriptionRenewsAtIsDateOnly: usage.subscriptionRenewsAtIsDateOnly,
                subscriptionExpiresAtIsDateOnly: usage.subscriptionExpiresAtIsDateOnly,
                updatedAt: usage.updatedAt,
                identity: usage.identity.map { identity in
                    ProviderIdentitySnapshot(
                        providerID: identity.providerID,
                        accountEmail: nil,
                        accountOrganization: nil,
                        loginMethod: nil)
                },
                dataConfidence: usage.dataConfidence)
        }

        /// Balance and cap only: events carry service names and are dropped. The cap passes through unchanged; its
        /// title is the same limit label Codex spend already carries in `providerCost.period`.
        private static func creditFigures(_ credits: CreditsSnapshot) -> CreditsSnapshot {
            CreditsSnapshot(
                remaining: credits.remaining,
                events: [],
                updatedAt: credits.updatedAt,
                codexCreditLimit: credits.codexCreditLimit,
                balanceReadSucceeded: credits.balanceReadSucceeded,
                creditsAvailable: credits.creditsAvailable,
                balanceIsWorkspace: credits.balanceIsWorkspace)
        }
    }

    public static let currentVersion = 1

    public let version: Int
    public let providers: [Provider]

    public init(version: Int = Self.currentVersion, providers: [Provider]) {
        self.version = version
        self.providers = providers
    }

    public func provider(_ provider: UsageProvider) -> Provider? {
        self.providers.first { $0.provider == provider.rawValue }
    }

    /// Shared wire encoding so the app and CLI ends stay symmetric.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> AppUsageSocketPayload {
        try JSONDecoder().decode(AppUsageSocketPayload.self, from: data)
    }
}

#if os(macOS)

// MARK: - Client

public enum AppUsageSocket {
    static let maximumPayloadBytes = 8 * 1024 * 1024

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("app-usage.sock", isDirectory: false)
            .path
    }

    /// Reads the running app's latest usage. Returns nil on any failure: no app, foreign owner, timeout,
    /// oversized or undecodable payload, or an unsupported payload version.
    public static func read(path: String = defaultPath, timeout: TimeInterval = 2) -> AppUsageSocketPayload? {
        guard let fd = self.connectedSocket(path: path, timeout: timeout) else { return nil }
        defer { close(fd) }
        guard self.peerUID(fd) == geteuid() else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                guard data.count <= self.maximumPayloadBytes else { return nil }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return nil
            }
        }

        guard let payload = try? AppUsageSocketPayload.decoded(from: data),
              payload.version == AppUsageSocketPayload.currentVersion
        else { return nil }
        return payload
    }

    /// A connected client socket with receive timeout and SIGPIPE suppression; the caller closes it.
    static func connectedSocket(path: String, timeout: TimeInterval) -> Int32? {
        guard var address = self.socketAddress(path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard self.configure(fd, timeoutOption: SO_RCVTIMEO, timeout: timeout) else {
            close(fd)
            return nil
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func socketAddress(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        // Leave room for the terminating NUL; reject embedded NULs that would silently truncate the path.
        guard !bytes.isEmpty,
              !bytes.contains(0),
              bytes.count < MemoryLayout.size(ofValue: address.sun_path)
        else { return nil }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return address
    }

    /// Returns false when SIGPIPE suppression could not be applied; Darwin rejects socket options with EINVAL once
    /// the peer has disconnected, and writing then would raise SIGPIPE.
    static func configure(_ fd: Int32, timeoutOption: Int32, timeout: TimeInterval) -> Bool {
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }
        let seconds = max(0, timeout)
        var interval = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, timeoutOption, &interval, socklen_t(MemoryLayout<timeval>.size))
        return true
    }

    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }
}

// MARK: - Server

/// Same-user-only Unix socket that writes one `AppUsageSocketPayload` to each connecting client, then closes.
/// The server never reads from clients. An exclusive `flock` on `<path>.lock` makes one instance the socket's owner.
/// `stop()` revokes clients still waiting for or receiving their payload: they are shut down at once, no further byte
/// is written to them, and `stop()` never waits on a client.
public final class AppUsageSocketServer: @unchecked Sendable {
    private struct BoundFile {
        let device: dev_t
        let inode: ino_t
    }

    private static let log = CodexBarLog.logger(LogCategories.app)

    private let path: String
    private let ownerUID: uid_t
    private let payload: @Sendable () async -> AppUsageSocketPayload
    private let queue = DispatchQueue(label: "com.steipete.codexbar.app-usage-socket")
    private let lock = NSLock()
    private var listenSource: DispatchSourceRead?
    private var boundFile: BoundFile?
    private var ownerLockFD: Int32?
    /// Bumped by every `stop()`; a client is answered only while the listener generation that accepted it is current.
    private var generation = 0
    /// Accepted, peer-checked clients waiting for their payload. Only `finish` closes them, under `lock`.
    private var pendingClients: Set<Int32> = []
    /// Clients whose payload is being written outside `lock`. Only `finish` closes them, under `lock`.
    private var inFlightClients: Set<Int32> = []

    public convenience init(
        path: String = AppUsageSocket.defaultPath,
        payload: @escaping @Sendable () async -> AppUsageSocketPayload)
    {
        self.init(path: path, ownerUID: geteuid(), payload: payload)
    }

    init(path: String, ownerUID: uid_t, payload: @escaping @Sendable () async -> AppUsageSocketPayload) {
        self.path = path
        self.ownerUID = ownerUID
        self.payload = payload
    }

    deinit {
        self.stop()
    }

    static func ownerLockPath(forSocketPath path: String) -> String {
        path + ".lock"
    }

    public func start() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.listenSource == nil else { return }
        guard var address = AppUsageSocket.socketAddress(path: self.path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        let directory = (self.path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        // Held until stop(): another instance (even one paused before listen) keeps the socket path untouched.
        let lockFD = try Self.acquireOwnerLock(path: Self.ownerLockPath(forSocketPath: self.path))
        var ownsLock = true
        defer {
            if ownsLock {
                close(lockFD)
            }
        }
        // As the lock holder, any socket left at the path is stale. Other file types stay and make bind fail.
        var existing = stat()
        if lstat(self.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFSOCK {
            unlink(self.path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError() }
        var ownsFD = true
        defer {
            if ownsFD {
                close(fd)
            }
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Self.posixError() }
        var bindFile = stat()
        guard chmod(self.path, 0o600) == 0,
              listen(fd, 8) == 0,
              lstat(self.path, &bindFile) == 0
        else {
            let error = Self.posixError()
            unlink(self.path)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        // Clients accepted by this listener belong to the generation it was started in.
        let listenerGeneration = self.generation
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingClients(listenFD: fd, generation: listenerGeneration)
        }
        source.setCancelHandler {
            close(fd)
        }
        ownsFD = false
        ownsLock = false
        self.listenSource = source
        self.boundFile = BoundFile(device: bindFile.st_dev, inode: bindFile.st_ino)
        self.ownerLockFD = lockFD
        source.resume()
    }

    public func stop() {
        self.lock.lock()
        self.generation += 1
        // Shut down instead of closing: `finish` still owns each descriptor, so a reused fd number is never touched.
        // The server never reads, so only the write side is shut: a write in progress fails (EPIPE, SO_NOSIGPIPE set)
        // and stop() never waits on a client. SHUT_RDWR would not do: Darwin returns ENOTCONN without shutting the
        // write side when the peer has already half-closed (shutdown(SHUT_WR) on the client).
        for clientFD in self.pendingClients.union(self.inFlightClients) {
            shutdown(clientFD, SHUT_WR)
        }
        let source = self.listenSource
        let boundFile = self.boundFile
        let lockFD = self.ownerLockFD
        self.listenSource = nil
        self.boundFile = nil
        self.ownerLockFD = nil
        self.lock.unlock()

        guard let source else { return }
        source.cancel()
        // A newer app instance may have replaced the socket; only remove the file this server bound.
        var current = stat()
        if let boundFile,
           lstat(self.path, &current) == 0,
           current.st_dev == boundFile.device,
           current.st_ino == boundFile.inode
        {
            unlink(self.path)
        }
        // Closing the descriptor releases the flock; the lock file itself stays for the next owner.
        if let lockFD {
            close(lockFD)
        }
    }

    private static func acquireOwnerLock(path: String) throws -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? POSIXError(.EADDRINUSE) : POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private func acceptPendingClients(listenFD: Int32, generation: Int) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return
            }
            self.serve(clientFD, generation: generation)
        }
    }

    private func serve(_ clientFD: Int32, generation: Int) {
        _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
        // Accepted sockets inherit the listener's O_NONBLOCK on Darwin; writes rely on SO_SNDTIMEO instead.
        _ = fcntl(clientFD, F_SETFL, fcntl(clientFD, F_GETFL) & ~O_NONBLOCK)
        guard AppUsageSocket.configure(clientFD, timeoutOption: SO_SNDTIMEO, timeout: 2) else {
            close(clientFD)
            return
        }
        // Checked before the payload is built or any byte is written.
        let peerUID = AppUsageSocket.peerUID(clientFD)
        guard peerUID == self.ownerUID else {
            Self.log.warning(
                "Rejected app usage socket peer",
                metadata: ["uid": peerUID.map { String($0) } ?? "unknown"])
            close(clientFD)
            return
        }
        let accepted = self.lock.withLock {
            guard self.listenSource != nil, generation == self.generation else { return false }
            self.pendingClients.insert(clientFD)
            return true
        }
        guard accepted else {
            close(clientFD)
            return
        }
        // A pending response keeps the server alive until it resolves, so every client is closed by `finish`.
        let payload = self.payload
        let queue = self.queue
        Task {
            let data = try? await payload().encoded()
            queue.async {
                self.finish(clientFD, generation: generation, data: data)
            }
        }
    }

    /// Checks the client is still current under `lock`, writes without it, and closes under it again. Each fd stays
    /// in exactly one of `pendingClients`/`inFlightClients` until closed, so `stop()` can shut it down safely.
    private func finish(_ clientFD: Int32, generation: Int, data: Data?) {
        let writable: Data? = self.lock.withLock {
            self.pendingClients.remove(clientFD)
            guard generation == self.generation, self.listenSource != nil, let data else {
                if generation != self.generation {
                    Self.log.debug("Dropped app usage socket response after stop")
                }
                close(clientFD)
                return nil
            }
            self.inFlightClients.insert(clientFD)
            return data
        }
        guard let writable else { return }
        Self.writeAll(writable, to: clientFD)
        self.lock.withLock {
            self.inFlightClients.remove(clientFD)
            close(clientFD)
        }
    }

    var pendingClientCount: Int {
        self.lock.withLock { self.pendingClients.count }
    }

    var inFlightClientCount: Int {
        self.lock.withLock { self.inFlightClients.count }
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
#endif
