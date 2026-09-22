import Foundation

/// The lamp credentials, in `~/.config/solarmorph/config.json` with mode 0600.
/// `SOLARMORPH_CONFIG` overrides the path.
public struct MorphConfig: Codable {
    public var serial: String
    public var accountId: String
    public var ltk: String
    /// The CoreBluetooth identifier of the lamp on this Mac. It saves the scan.
    public var peripheralId: UUID?

    public init(serial: String, accountId: String, ltk: String, peripheralId: UUID? = nil) {
        self.serial = serial
        self.accountId = accountId
        self.ltk = ltk
        self.peripheralId = peripheralId
    }

    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment["SOLARMORPH_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/solarmorph/config.json")
    }

    public static func load() throws -> MorphConfig {
        guard let data = try? Data(contentsOf: url) else { throw MorphError.notPaired }
        return try JSONDecoder().decode(MorphConfig.self, from: data)
    }

    public func save() throws {
        let url = Self.url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        // Write a new file and rename it, so that a reader (the daemon, or a
        // second command) never sees a partial file. The new file has its final
        // mode from the start, so the key is never readable by other users.
        let temporary = url.path + ".tmp-\(getpid())"
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw MorphError.usage("Could not write \(temporary): \(String(cString: strerror(errno)))")
        }
        do {
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try file.write(contentsOf: data)
            try file.close()
            guard rename(temporary, url.path) == 0 else {
                throw MorphError.usage("Could not replace \(url.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temporary)
            throw error
        }
    }
}
