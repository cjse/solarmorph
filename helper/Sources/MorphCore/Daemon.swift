import Foundation

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
}

/// Identifies the binary. A daemon from an old build stops when a new build talks to it.
public let buildId: String = {
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(Int(modified))-\(attributes?[.size] as? Int ?? 0)"
}()

public struct DaemonRequest: Codable {
    public var build: String
    public var args: [String]
}

public struct DaemonReply: Codable {
    public var state: LampState?
    public var error: String?
    /// `notPaired`, `usage`, or `stale` (the daemon is from a different build and stops).
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
private struct LineReader {
    let descriptor: Int32
    private var buffer = Data()

    init(_ descriptor: Int32) { self.descriptor = descriptor }

    mutating func next() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer.prefix(upTo: end))
                buffer = Data(buffer.suffix(from: end + 1))
                return line
            }
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// - Returns: false when the other end is gone.
@discardableResult
private func writeLine(_ data: Data, to descriptor: Int32) -> Bool {
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

private func setReceiveTimeout(_ descriptor: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

// MARK: - Client

public enum DaemonClient {
    /// Connect to the daemon. nil when no daemon listens.
    static func open() -> Int32? {
        guard let address = try? unixAddress(DaemonPaths.socket) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        guard withSocketAddress(address, { connect(descriptor, $0, $1) }) == 0 else {
            close(descriptor)
            return nil
        }
        // The daemon possibly connects to the lamp first, with its retries.
        setReceiveTimeout(descriptor, seconds: 120)
        return descriptor
    }

    public static var isRunning: Bool {
        guard let descriptor = open() else { return false }
        close(descriptor)
        return true
    }

    static func exchange(_ args: [String], on descriptor: Int32) throws -> DaemonReply {
        defer { close(descriptor) }
        writeLine(try JSONEncoder().encode(DaemonRequest(build: buildId, args: args)), to: descriptor)
        var reader = LineReader(descriptor)
        guard let line = reader.next() else {
            throw MorphError.bluetooth("The daemon closed the connection without a reply. See \(DaemonPaths.log).")
        }
        return try JSONDecoder().decode(DaemonReply.self, from: line)
    }

    /// Start a detached daemon and wait until it listens.
    static func start() -> Int32? {
        guard let executable = Bundle.main.executableURL else { return nil }
        try? FileManager.default.createDirectory(
            at: DaemonPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: DaemonPaths.log, contents: nil, attributes: [.posixPermissions: 0o600])

        let process = Process()
        process.executableURL = executable
        process.arguments = ["daemon"]
        // The daemon must not hold the stdout of this process. A caller that
        // waits for the end of the output then waits for the daemon.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle(forWritingAtPath: DaemonPaths.log) ?? FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        for _ in 0..<100 {
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
                } catch {
                    // The daemon reached its idle limit at the same moment. Start a new one.
                    guard attempt == 1 else { throw error }
                    for _ in 0..<60 where isRunning { usleep(50_000) }
                    continue
                }
                if reply.code == "stale" {
                    // The old daemon stops. Wait until its socket is gone, then start a new one.
                    for _ in 0..<60 where isRunning { usleep(50_000) }
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
                setReceiveTimeout(descriptor, seconds: 0)
                writeLine(try JSONEncoder().encode(DaemonRequest(build: buildId, args: ["watch"])), to: descriptor)

                var reader = LineReader(descriptor)
                var restart = false
                while let line = reader.next() {
                    guard let reply = try? JSONDecoder().decode(DaemonReply.self, from: line) else { continue }
                    if reply.code == "stale", attempt == 1 {
                        restart = true
                        break
                    }
                    onReply(reply)
                }
                guard restart else { return }
                for _ in 0..<60 where isRunning { usleep(50_000) }
            }
        }.value
    }

    /// - Returns: false when no daemon was active.
    public static func stop() async throws -> Bool {
        try await Task.detached {
            guard let descriptor = open() else { return false }
            _ = try exchange(["daemon-stop"], on: descriptor)
            return true
        }.value
    }
}

// MARK: - Server

/// Runs the commands one after the other on one lamp connection, and sends
/// the live state to the watchers.
actor LampSession {
    private let lamp = Lamp()
    private let idle: TimeInterval
    private let log: (String) -> Void
    private let shutdown: @Sendable () -> Void
    private var poweredOn = false
    private var connectedSerial: String?
    private var tail: Task<Void, Never>?
    private var generation = 0

    /// The sockets of the `watch` clients. The session owns them and closes them.
    private var watchers: Set<Int32> = []
    private var latest: LampState?
    private var broadcastPending = false
    /// True while a live session exists, so that only its loss starts a recovery.
    private var sessionUp = false

    init(idle: TimeInterval, log: @escaping (String) -> Void, shutdown: @escaping @Sendable () -> Void) {
        self.idle = idle
        self.log = log
        self.shutdown = shutdown
        lamp.log = log
    }

    func start() {
        lamp.onStateChange = { [weak self] state in Task { await self?.stateChanged(state) } }
        lamp.onDisconnect = { [weak self] in Task { await self?.lampDisconnected() } }
    }

    /// An actor method can interleave with a second call at each `await`. The
    /// chain makes sure that a command starts only after the previous one ends.
    func submit(_ args: [String]) async -> DaemonReply {
        let previous = tail
        let work = Task { () -> DaemonReply in
            await previous?.value
            return await self.perform(args)
        }
        // The live state starts after the reply, so that it does not make the
        // first command slower. The next command waits for it.
        tail = Task {
            let reply = await work.value
            await self.ensureLive(seed: reply.state)
        }
        return await work.value
    }

    func close() async {
        await tail?.value
        for descriptor in watchers { Darwin.close(descriptor) }
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

    func removeWatcher(_ descriptor: Int32) {
        guard watchers.remove(descriptor) != nil else { return }
        Darwin.close(descriptor)
        if watchers.isEmpty { scheduleIdleStop() }
    }

    private func send(_ reply: DaemonReply, to descriptors: Set<Int32>) {
        guard let data = try? JSONEncoder().encode(reply) else { return }
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
        guard !watchers.isEmpty else { return }
        log("The lamp disconnected while a watch was open. Connecting again.")
        let reply = await submit(["status"])
        send(reply, to: watchers)
        if reply.state == nil {
            for descriptor in watchers { removeWatcher(descriptor) }
        }
    }

    // MARK: Commands

    private func ensureLive(seed: LampState?) async {
        guard await lamp.isReady, !(await lamp.isLive) else { return }
        do {
            // A state with the attributes is complete, so it saves the reads.
            try await lamp.enableLiveState(seed: seed?.daylight != nil ? seed : nil)
            sessionUp = true
        } catch {
            log("The live state did not start: \(error)")
        }
    }

    private func perform(_ args: [String]) async -> DaemonReply {
        generation += 1
        defer { scheduleIdleStop() }
        do {
            let command = try LampCommand(arguments: args)
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
            if self.generation == expected, self.watchers.isEmpty {
                self.log("Idle for \(Int(self.idle)) s. Stopping.")
                await self.lamp.disconnect()
                self.shutdown()
            }
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
    /// Run the daemon. This function does not return.
    public static func run(idle: TimeInterval) async throws -> Never {
        let started = Date()
        let log: (String) -> Void = { message in
            FileHandle.standardError.write(Data(String(format: "%8.2f  %@\n", Date().timeIntervalSince(started), message).utf8))
        }

        try FileManager.default.createDirectory(
            at: DaemonPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Only one daemon. The lock goes away with the process, so it cannot be stale.
        // A daemon that stops for a new build holds the lock for a moment more, so try for two seconds.
        let lock = Darwin.open(DaemonPaths.lock, O_CREAT | O_RDWR, 0o600)
        var locked = false
        for _ in 0..<40 where !locked {
            locked = lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0
            if !locked { usleep(50_000) }
        }
        guard locked else {
            log("A different daemon holds the lock. Stopping.")
            exit(0)
        }

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
        log("Listening on \(DaemonPaths.socket), build \(ownBuild), idle limit \(Int(idle)) s")

        let shutdown: @Sendable () -> Void = {
            unlink(DaemonPaths.socket)
            exit(0)
        }
        let session = LampSession(idle: idle, log: log, shutdown: shutdown)
        await session.start()

        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signal(SIGTERM, SIG_IGN)
        terminate.setEventHandler {
            Task {
                await session.close()
                shutdown()
            }
        }
        terminate.resume()

        let acceptor = Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                Task.detached {
                    var reader = LineReader(client)
                    guard let line = reader.next(),
                          let request = try? JSONDecoder().decode(DaemonRequest.self, from: line) else {
                        close(client)
                        return
                    }
                    if request.build == ownBuild, request.args == ["watch"] {
                        log("→ watch")
                        await session.addWatcher(client)
                        // The client sends nothing more, so the end of the read is the end of the
                        // watch. The wait is on its own thread, because it can be long.
                        Thread {
                            var byte: UInt8 = 0
                            while read(client, &byte, 1) > 0 {}
                            Task {
                                await session.removeWatcher(client)
                                log("A watcher left.")
                            }
                        }.start()
                        return
                    }

                    let reply: DaemonReply
                    var stopAfterReply = false
                    if request.build != ownBuild {
                        log("A client from build \(request.build) connected. Stopping, so that it can start its own daemon.")
                        reply = DaemonReply(code: "stale")
                        stopAfterReply = true
                    } else if request.args == ["daemon-stop"] {
                        log("Stop requested.")
                        reply = DaemonReply(stopped: true)
                        stopAfterReply = true
                    } else {
                        log("→ \(request.args.joined(separator: " "))")
                        reply = await session.submit(request.args)
                        log("← \(reply.error ?? "ok")")
                    }
                    if stopAfterReply {
                        // Free the socket name before the reply, so that the client can start a new daemon immediately.
                        unlink(DaemonPaths.socket)
                        await session.close()
                    }
                    if let data = try? JSONEncoder().encode(reply) { writeLine(data, to: client) }
                    close(client)
                    if stopAfterReply { exit(0) }
                }
            }
        }
        acceptor.start()

        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}
