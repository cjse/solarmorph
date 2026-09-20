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
        // Create the file with its final mode, so the key is never world-readable.
        let data = try encoder.encode(self)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try data.write(to: url)
    }
}
