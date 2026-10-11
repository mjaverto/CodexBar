import Foundation

// MARK: - Payload

/// Usage the running menu bar app publishes for same-user CLI processes that cannot read login-keychain secrets
/// (for example `codexbar usage` over SSH). A private app-to-CLI channel whose format can change in any release.
/// Carries usage and plan only; never credentials or account email, organization, or ID.
public struct AppUsageSocketPayload: Codable, Sendable {
    public struct Provider: Codable, Sendable {
        /// `UsageProvider.rawValue`; a string so providers unknown to an older CLI don't break decoding.
        public let provider: String
        public let usage: UsageSnapshot
        public let credits: CreditsSnapshot?

        public init(provider: UsageProvider, usage: UsageSnapshot, credits: CreditsSnapshot?) {
            self.provider = provider.rawValue
            self.usage = usage
            self.credits = credits
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
        guard self.peerIsCurrentUser(fd) else { return nil }

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

    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }
}

// MARK: - Server

/// Same-user-only Unix socket that writes one `AppUsageSocketPayload` to each connecting client, then closes.
/// The server never reads from clients.
public final class AppUsageSocketServer: @unchecked Sendable {
    private struct BoundFile {
        let device: dev_t
        let inode: ino_t
    }

    private let path: String
    private let payload: @Sendable () async -> AppUsageSocketPayload
    private let queue = DispatchQueue(label: "com.steipete.codexbar.app-usage-socket")
    private let lock = NSLock()
    private var listenSource: DispatchSourceRead?
    private var boundFile: BoundFile?

    public init(
        path: String = AppUsageSocket.defaultPath,
        payload: @escaping @Sendable () async -> AppUsageSocketPayload)
    {
        self.path = path
        self.payload = payload
    }

    deinit {
        self.stop()
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
        // Never steal a live listener (another running instance); remove only a stale socket nobody answers.
        // Any other file type is left in place and makes bind fail.
        var existing = stat()
        if lstat(self.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFSOCK {
            if let probe = AppUsageSocket.connectedSocket(path: self.path, timeout: 1) {
                close(probe)
                throw POSIXError(.EADDRINUSE)
            }
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

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingClients(listenFD: fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        ownsFD = false
        self.listenSource = source
        self.boundFile = BoundFile(device: bindFile.st_dev, inode: bindFile.st_ino)
        source.resume()
    }

    public func stop() {
        self.lock.lock()
        let source = self.listenSource
        let boundFile = self.boundFile
        self.listenSource = nil
        self.boundFile = nil
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
    }

    private func acceptPendingClients(listenFD: Int32) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return
            }
            self.serve(clientFD)
        }
    }

    private func serve(_ clientFD: Int32) {
        _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
        // Accepted sockets inherit the listener's O_NONBLOCK on Darwin; writes rely on SO_SNDTIMEO instead.
        _ = fcntl(clientFD, F_SETFL, fcntl(clientFD, F_GETFL) & ~O_NONBLOCK)
        guard AppUsageSocket.configure(clientFD, timeoutOption: SO_SNDTIMEO, timeout: 2),
              AppUsageSocket.peerIsCurrentUser(clientFD)
        else {
            close(clientFD)
            return
        }
        let payload = self.payload
        let queue = self.queue
        Task {
            let data = try? await payload().encoded()
            queue.async {
                if let data {
                    Self.writeAll(data, to: clientFD)
                }
                close(clientFD)
            }
        }
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
