import Foundation
import MachO

// The daemon keeps the lamp connection open between commands, so that a command
// does not pay for the connect, the discovery, and the handshake each time.
//
// It starts on demand: the first command starts it, and it stops after an idle
// period. A process that Raycast starts uses the Bluetooth permission of
// Raycast, which a launchd service does not get. The idle stop also gives the
// lamp back to the MyDyson app, because the lamp probably accepts one connection.
//
// The protocol is one JSON line for the request and one JSON line for the reply,
// on a Unix socket next to the configuration file.

public enum DaemonPaths {
    static var directory: URL { MorphConfig.url.deletingLastPathComponent() }
    public static var socket: String { directory.appendingPathComponent("daemon.sock").path }
    public static var lock: String { directory.appendingPathComponent("daemon.lock").path }
    public static var log: String { directory.appendingPathComponent("daemon.log").path }
    /// The previous log. The daemon moves the log here when it is larger than `logLimit`.
    public static var oldLog: String { log + ".1" }
    public static let logLimit = 1_000_000
}

/// Move a log that is larger than `limit` to `oldLog`, and replace an older one there.
///
/// - Returns: true when it moved the log.
@discardableResult
func rotateLog(_ log: String, to oldLog: String, limit: Int) -> Bool {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: log))?[.size] as? Int, size > limit else {
        return false
    }
    return rename(log, oldLog) == 0
}

/// True when the standard error of this process writes to the file at `path`.
func standardErrorIs(_ path: String) -> Bool {
    var own = stat()
    var file = stat()
    guard fstat(STDERR_FILENO, &own) == 0, stat(path, &file) == 0 else { return false }
    return own.st_dev == file.st_dev && own.st_ino == file.st_ino
}

/// Identifies the binary. A daemon from a different build stops when a new build talks to it.
///
/// It is the UUID that the linker computes from the content of the binary. A
/// copy of the same build has the same UUID, also after `codesign` and with a
/// different file date, so the helper of Raycast and the helper in `.build`
/// share one daemon.
public let buildId: String = executableUUID() ?? {
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(Int(modified))-\(attributes?[.size] as? Int ?? 0)"
}()

/// The `LC_UUID` of the main executable, from its Mach-O header in memory.
func executableUUID() -> String? {
    guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else { return nil }
    var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
        let load = command.loadUnaligned(as: load_command.self)
        if load.cmd == LC_UUID {
            return UUID(uuid: command.loadUnaligned(as: uuid_command.self).uuid).uuidString
        }
        command = command.advanced(by: Int(load.cmdsize))
    }
    return nil
}

public struct DaemonRequest: Codable {
    public var build: String
    public var args: [String]
    /// The idle limit that the client wants, in seconds. The daemon takes it from
    /// each request, so that a changed preference applies without a restart.
    public var idle: TimeInterval?

    init(args: [String]) {
        build = buildId
        self.args = args
        idle = ProcessInfo.processInfo.environment["SOLARMORPH_IDLE"].flatMap(TimeInterval.init)
    }
}

public struct DaemonReply: Codable {
    public var state: LampState?
    public var error: String?
    /// `notPaired`, `usage`, or `stale` (the daemon stops, because it is from a different
    /// build or reached its idle limit; the client starts a new one).
    public var code: String?
    public var stopped: Bool?

    init(state: LampState? = nil, error: String? = nil, code: String? = nil, stopped: Bool? = nil) {
        self.state = state
        self.error = error
        self.code = code
        self.stopped = stopped
    }

    init(failure: Error) {
        let known = failure as? MorphError
        error = known?.description ?? failure.localizedDescription
        switch known {
        case .notPaired: code = "notPaired"
        case .usage: code = "usage"
        default: code = nil
        }
    }
}

// MARK: - Socket helpers

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw MorphError.usage("The socket path is too long: \(path)") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
    }
    return address
}

private func withSocketAddress<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var copy = address
    return withUnsafePointer(to: &copy) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

/// Reads lines from a socket. A watch connection carries many lines, so the
/// bytes after a newline stay in the buffer for the next call.
struct LineReader {
    let descriptor: Int32
    private var buffer = Data()
    /// True when the last `next()` ended at the receive timeout, and not at the end of the connection.
    private(set) var timedOut = false

    init(_ descriptor: Int32) { self.descriptor = descriptor }

    mutating func next() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        timedOut = false
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer.prefix(upTo: end))
                buffer = Data(buffer.suffix(from: end + 1))
                return line
            }
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { timedOut = true }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// - Returns: false when the other end is gone, or when the send timeout ends the write.
@discardableResult
func writeLine(_ data: Data, to descriptor: Int32) -> Bool {
    let bytes = [UInt8](data) + [0x0A]
    return bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

/// `SO_RCVTIMEO` or `SO_SNDTIMEO`. 0 seconds means no limit.
private func setTimeout(_ descriptor: Int32, _ option: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

/// True when the other end closed the connection. It does not wait, and it leaves the data in the socket.
func peerClosed(_ descriptor: Int32) -> Bool {
    var byte: UInt8 = 0
    return recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Wait for async work on the current thread. Use it only on the thread of a
/// connection, never on a thread of the concurrency pool.
private func runBlocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}

// MARK: - Client

public enum DaemonClient {
    /// The daemon closed the connection without a reply, because it stopped at the same moment.
    struct ConnectionClosed: Error {}

    /// Connect to the daemon. nil when no daemon listens.
    static func open() -> Int32? {
        guard let address = try? unixAddress(DaemonPaths.socket) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        guard withSocketAddress(address, { connect(descriptor, $0, $1) }) == 0 else {
            close(descriptor)
            return nil
        }
        // A write to a daemon that just stopped then fails, and does not stop this process with SIGPIPE.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // The daemon possibly connects to the lamp first, with its retries.
        setTimeout(descriptor, SO_RCVTIMEO, seconds: 120)
        return descriptor
    }

    public static var isRunning: Bool {
        guard let descriptor = open() else { return false }
        close(descriptor)
        return true
    }

    /// Wait until the socket of a daemon that stops is gone.
    static func waitUntilStopped() {
        for _ in 0..<60 where isRunning { usleep(50_000) }
    }

    static func exchange(_ args: [String], on descriptor: Int32) throws -> DaemonReply {
        defer { close(descriptor) }
        guard writeLine(try JSONEncoder().encode(DaemonRequest(args: args)), to: descriptor) else {
            throw ConnectionClosed()
        }
        var reader = LineReader(descriptor)
        guard let line = reader.next() else {
            // The daemon possibly still runs the command, so the caller must not send it again.
            if reader.timedOut {
                throw MorphError.bluetooth("The background process did not reply in time. See \(DaemonPaths.log).")
            }
            throw ConnectionClosed()
        }
        return try JSONDecoder().decode(DaemonReply.self, from: line)
    }

    /// Start a detached daemon and wait until it listens.
    static func start() -> Int32? {
        guard let executable = Bundle.main.executableURL else { return nil }
        try? FileManager.default.createDirectory(
            at: DaemonPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Append, so that the log keeps the history of the earlier daemons. The daemon limits the size.
        let log = Darwin.open(DaemonPaths.log, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["daemon"]
        // The daemon must not hold the stdout of this process. A caller that
        // waits for the end of the output then waits for the daemon.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = log >= 0 ? FileHandle(fileDescriptor: log, closeOnDealloc: true) : FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // A daemon that stops holds the lock until it has given the lamp back,
        // and the new daemon waits up to 5 seconds for the lock.
        for _ in 0..<160 {
            if let descriptor = open() { return descriptor }
            usleep(50_000)
        }
        return nil
    }

    /// Run a lamp command through the daemon.
    ///
    /// - Returns: nil when no daemon is available, so that the caller can use the direct mode.
    public static func run(_ args: [String]) async throws -> LampState? {
        try await Task.detached { () -> LampState? in
            for attempt in 1...2 {
                guard let descriptor = open() ?? start() else { return nil }
                let reply: DaemonReply
                do {
                    reply = try exchange(args, on: descriptor)
                } catch is ConnectionClosed {
                    guard attempt == 1 else {
                        throw MorphError.bluetooth("The daemon closed the connection without a reply. See \(DaemonPaths.log).")
                    }
                    waitUntilStopped()
                    continue
                }
                if reply.code == "stale" {
                    waitUntilStopped()
                    continue
                }
                if let state = reply.state { return state }
                switch reply.code {
                case "notPaired": throw MorphError.notPaired
                case "usage": throw MorphError.usage(reply.error ?? "Usage error")
                default: throw MorphError.bluetooth(reply.error ?? "The daemon gave no state.")
                }
            }
            return nil
        }.value
    }

    /// Follow the live state. `onReply` gets the state at the start, then one reply
    /// for each change, from any source: a command, the MyDyson app, or the lamp itself.
    /// The daemon does not reach its idle limit while a watch is open.
    ///
    /// Returns when the daemon closes the watch.
    public static func watch(onReply: @escaping @Sendable (DaemonReply) -> Void) async throws {
        try await Task.detached {
            for attempt in 1...2 {
                guard let descriptor = open() ?? start() else {
                    throw MorphError.bluetooth("The background process did not start. See \(DaemonPaths.log).")
                }
                defer { close(descriptor) }
                // A watch is quiet for as long as the lamp does not change.
                setTimeout(descriptor, SO_RCVTIMEO, seconds: 0)
                var restart = !writeLine(try JSONEncoder().encode(DaemonRequest(args: ["watch"])), to: descriptor)

                var reader = LineReader(descriptor)
                while !restart, let line = reader.next() {
                    guard let reply = try? JSONDecoder().decode(DaemonReply.self, from: line) else { continue }
                    if reply.code == "stale", attempt == 1 {
                        restart = true
                        break
                    }
                    onReply(reply)
                }
                guard restart, attempt == 1 else { return }
                waitUntilStopped()
            }
        }.value
    }

    /// - Returns: false when no daemon was active.
    public static func stop() async throws -> Bool {
        try await Task.detached {
            guard let descriptor = open() else { return false }
            do {
                _ = try exchange(["daemon-stop"], on: descriptor)
            } catch is ConnectionClosed {
                // It stopped at the same moment.
            }
            return true
        }.value
    }
}

// MARK: - Server

/// Runs the commands one after the other on one lamp connection, and sends
/// the live state to the watchers.
actor LampSession {
    private let lamp = Lamp()
    private var idle: TimeInterval
    private let log: (String) -> Void
    private let exitProcess: @Sendable () -> Void
    private var poweredOn = false
    private var connectedSerial: String?
    private var tail: Task<Void, Never>?
    private var generation = 0
    /// True from the start of the stop. A request then gets `stale`, and the client starts a new daemon.
    private var stopping = false

    /// The sockets of the `watch` clients. The thread of each connection owns
    /// its socket and closes it. The session only shuts a socket down, so that
    /// its number cannot go to a new connection while the thread still uses it.
    private var watchers: Set<Int32> = []
    private var latest: LampState?
    private var broadcastPending = false
    /// True while a live session exists, so that only its loss starts a recovery.
    private var sessionUp = false

    init(idle: TimeInterval, log: @escaping (String) -> Void, exitProcess: @escaping @Sendable () -> Void) {
        self.idle = max(idle, DaemonServer.minimumIdle)
        self.log = log
        self.exitProcess = exitProcess
        lamp.log = log
    }

    func setIdle(_ seconds: TimeInterval) {
        let limit = max(seconds, DaemonServer.minimumIdle)
        guard limit != idle else { return }
        log("The idle limit is now \(Int(limit)) s")
        idle = limit
    }

    func start() {
        lamp.onStateChange = { [weak self] state in Task { await self?.stateChanged(state) } }
        lamp.onDisconnect = { [weak self] in Task { await self?.lampDisconnected() } }
    }

    /// An actor method can interleave with a second call at each `await`. The
    /// chain makes sure that a command starts only after the previous one ends.
    ///
    /// - Parameter clientGone: true when the client no longer waits for the reply.
    func submit(_ args: [String], clientGone: (@Sendable () -> Bool)? = nil) async -> DaemonReply {
        let previous = tail
        let work = Task { () -> DaemonReply in
            await previous?.value
            return await self.perform(args, clientGone: clientGone)
        }
        // The live state starts after the reply, so that it does not make the
        // first command slower. The next command waits for it.
        tail = Task {
            let reply = await work.value
            await self.ensureLive(seed: reply.state)
        }
        return await work.value
    }

    /// Refuse new work, free the socket name, let the current command end, and
    /// give the lamp back. The caller then ends the process.
    func shutDown() async {
        stopping = true
        // A new client then starts a new daemon. That daemon waits for the lock,
        // which this process holds until it ends, so it cannot lose its socket here.
        unlink(DaemonPaths.socket)
        await tail?.value
        for descriptor in watchers { Darwin.shutdown(descriptor, SHUT_RDWR) }
        watchers = []
        await lamp.disconnect()
    }

    // MARK: Watchers

    func addWatcher(_ descriptor: Int32) async {
        generation += 1
        watchers.insert(descriptor)
        // The reply goes out before the live state starts, so that the list shows fast.
        // The changes arrive through `stateChanged` when the live state is on.
        let reply = await submit(["status"])
        guard watchers.contains(descriptor) else { return }
        send(reply, to: [descriptor])
        if reply.state == nil { removeWatcher(descriptor) }
    }

    /// The thread of the connection sees the end of its read, and closes the socket.
    func removeWatcher(_ descriptor: Int32) {
        guard watchers.remove(descriptor) != nil else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        if watchers.isEmpty { scheduleIdleStop() }
    }

    private func send(_ reply: DaemonReply, to descriptors: Set<Int32>) {
        guard let data = try? JSONEncoder().encode(reply) else { return }
        // The send timeout of the socket ends the write to a client that does not read.
        for descriptor in descriptors where !writeLine(data, to: descriptor) {
            removeWatcher(descriptor)
        }
    }

    /// The lamp sends many notifications while it ramps to a value, so send at most ten states each second.
    private func stateChanged(_ state: LampState) {
        latest = state
        guard !broadcastPending, !watchers.isEmpty else { return }
        broadcastPending = true
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.flush()
        }
    }

    private func flush() {
        broadcastPending = false
        if let latest { send(DaemonReply(state: latest), to: watchers) }
    }

    private func lampDisconnected() async {
        guard sessionUp else { return }
        sessionUp = false
        guard !watchers.isEmpty, !stopping else { return }
        log("The lamp disconnected while a watch was open. Connecting again.")
        let reply = await submit(["status"])
        send(reply, to: watchers)
        if reply.state == nil {
            for descriptor in watchers { removeWatcher(descriptor) }
        }
    }

    // MARK: Commands

    private func ensureLive(seed: LampState?) async {
        guard !stopping, await lamp.isReady, !(await lamp.isLive) else { return }
        do {
            // A state with the attributes is complete, so it saves the reads.
            try await lamp.enableLiveState(seed: seed?.daylight != nil ? seed : nil)
            sessionUp = true
        } catch {
            log("The live state did not start: \(error)")
        }
    }

    private func perform(_ args: [String], clientGone: (@Sendable () -> Bool)?) async -> DaemonReply {
        guard !stopping else { return DaemonReply(code: "stale") }
        generation += 1
        defer { scheduleIdleStop() }
        // The client gives up after a time limit. A command that nobody waits
        // for must not change the lamp later, when the user does not expect it.
        func abandoned() -> Bool {
            guard clientGone?() == true else { return false }
            log("The client left before the command ran. Skipped it.")
            return true
        }
        do {
            let command = try LampCommand(arguments: args)
            if abandoned() { return DaemonReply(error: "The client left.") }
            // Read the file each time, so that a new pairing takes effect.
            var config = try MorphConfig.load()
            if !poweredOn {
                try await lamp.powerOn()
                poweredOn = true
            }
            if connectedSerial != config.serial {
                await lamp.disconnect()
            }

            for attempt in 1...2 {
                let wasReady = await lamp.isReady
                do {
                    if !wasReady {
                        let id = try await lamp.connect(
                            serial: config.serial, accountId: config.accountId, ltkHex: config.ltk,
                            cachedId: config.peripheralId)
                        connectedSerial = config.serial
                        if id != config.peripheralId {
                            config.peripheralId = id
                            try? config.save()
                        }
                        if abandoned() { return DaemonReply(error: "The client left.") }
                    }
                    return DaemonReply(state: try await command.run(on: lamp))
                } catch let error as MorphError {
                    // A connection that the lamp dropped during the idle time shows
                    // as a failure of the first operation. Connect again one time.
                    guard attempt == 1, wasReady, error.isConnectionLoss else { throw error }
                    log("The connection was lost (\(error)). Connecting again.")
                    await lamp.disconnect()
                }
            }
            throw MorphError.bluetooth("The lamp connection failed two times.")
        } catch {
            return DaemonReply(failure: error)
        }
    }

    private func scheduleIdleStop() {
        generation += 1
        let expected = generation
        Task {
            try? await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            // An open watch is use, so the limit applies only after the last watcher left.
            // There is no `await` between the check and the start of the stop, so no
            // command can start in between.
            guard self.generation == expected, self.watchers.isEmpty, !self.stopping else { return }
            self.log("Idle for \(Int(self.idle)) s. Stopping.")
            await self.shutDown()
            self.exitProcess()
        }
    }
}

extension MorphError {
    var isConnectionLoss: Bool {
        switch self {
        case .timeout, .bluetooth: return true
        default: return false
        }
    }
}

public enum DaemonServer {
    public static let minimumIdle: TimeInterval = 5

    /// Run the daemon. This function does not return.
    public static func run(idle: TimeInterval) async throws -> Never {
        let started = Date()
        let log: (String) -> Void = { message in
            FileHandle.standardError.write(Data(String(format: "%8.2f  %@\n", Date().timeIntervalSince(started), message).utf8))
        }

        try FileManager.default.createDirectory(
            at: DaemonPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Only one daemon. The lock goes away with the process, so it cannot be stale.
        // A daemon that stops holds the lock until it has given the lamp back, so try for five seconds.
        let lock = Darwin.open(DaemonPaths.lock, O_CREAT | O_RDWR, 0o600)
        var locked = false
        for _ in 0..<100 where !locked {
            locked = lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0
            if !locked { usleep(50_000) }
        }
        guard locked else {
            log("A different daemon holds the lock. Stopping.")
            exit(0)
        }

        // Only the daemon that has the lock changes the log, so two daemons cannot both move it.
        // A daemon that a person started in a terminal writes to the terminal, so leave the file alone.
        if standardErrorIs(DaemonPaths.log),
            rotateLog(DaemonPaths.log, to: DaemonPaths.oldLog, limit: DaemonPaths.logLimit)
        {
            let fresh = Darwin.open(DaemonPaths.log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            if fresh >= 0 {
                dup2(fresh, STDERR_FILENO)
                Darwin.close(fresh)
            }
        }
        let date = ISO8601DateFormatter.string(from: started, timeZone: .current, formatOptions: [.withInternetDateTime])
        FileHandle.standardError.write(Data("\n=== Daemon \(getpid()) started \(date) ===\n".utf8))

        // Leave the session of the process that started the daemon, so that the
        // end of that process or of its terminal does not stop the daemon.
        setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        let address = try unixAddress(DaemonPaths.socket)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        unlink(DaemonPaths.socket)
        guard listener >= 0, withSocketAddress(address, { bind(listener, $0, $1) }) == 0 else {
            throw MorphError.usage("Could not bind \(DaemonPaths.socket): \(String(cString: strerror(errno)))")
        }
        chmod(DaemonPaths.socket, 0o600)
        listen(listener, 8)
        let ownBuild = buildId
        log("Listening on \(DaemonPaths.socket), build \(ownBuild), idle limit \(Int(max(idle, minimumIdle))) s")

        let session = LampSession(idle: idle, log: log, exitProcess: { exit(0) })
        await session.start()

        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signal(SIGTERM, SIG_IGN)
        terminate.setEventHandler {
            Task {
                await session.shutDown()
                exit(0)
            }
        }
        terminate.resume()

        let acceptor = Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    // For example, too many open files. Do not spin.
                    if errno != EINTR { usleep(100_000) }
                    continue
                }
                // Each connection has its own thread for its blocking reads and writes,
                // so that a slow client cannot block the concurrency pool.
                Thread { serve(client, session: session, ownBuild: ownBuild, log: log) }.start()
            }
        }
        acceptor.start()

        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    /// Handle one connection on its own thread. This thread owns the socket and closes it.
    private static func serve(_ client: Int32, session: LampSession, ownBuild: String, log: @escaping (String) -> Void) {
        // A client sends its request immediately. The limits stop a client that
        // does not send or does not read from holding this thread or the session.
        setTimeout(client, SO_RCVTIMEO, seconds: 5)
        setTimeout(client, SO_SNDTIMEO, seconds: 2)
        var reader = LineReader(client)
        guard let line = reader.next(), let request = try? JSONDecoder().decode(DaemonRequest.self, from: line) else {
            close(client)
            return
        }

        func stop(reply: DaemonReply) -> Never {
            runBlocking { await session.shutDown() }
            if let data = try? JSONEncoder().encode(reply) { writeLine(data, to: client) }
            exit(0)
        }

        guard request.build == ownBuild else {
            log("A client from build \(request.build) connected. Stopping, so that it can start its own daemon.")
            stop(reply: DaemonReply(code: "stale"))
        }
        if let idle = request.idle {
            runBlocking { await session.setIdle(idle) }
        }

        switch request.args {
        case ["daemon-stop"]:
            log("Stop requested.")
            stop(reply: DaemonReply(stopped: true))

        case ["watch"]:
            log("→ watch")
            // A watch is quiet for as long as the lamp does not change.
            setTimeout(client, SO_RCVTIMEO, seconds: 0)
            runBlocking { await session.addWatcher(client) }
            // The client sends nothing more, so the end of the read is the end of the
            // watch. The read also ends when the session shuts the socket down.
            var byte: UInt8 = 0
            while read(client, &byte, 1) > 0 {}
            runBlocking { await session.removeWatcher(client) }
            close(client)
            log("A watcher left.")

        default:
            log("→ \(request.args.joined(separator: " "))")
            let reply = runBlocking { await session.submit(request.args, clientGone: { peerClosed(client) }) }
            log("← \(reply.error ?? reply.code ?? "ok")")
            if let data = try? JSONEncoder().encode(reply) { writeLine(data, to: client) }
            close(client)
        }
    }
}
