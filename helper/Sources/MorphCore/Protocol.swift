import Foundation

/// Wire-level constants and framing for the Dyson BLE light protocol.
///
/// Source: docs/PROTOCOL.md in rummeyer/homebridge-dyson-solarcycle-morph,
/// which documents the work of S-Termi in cmgrayb/hass-dyson.

public enum MorphError: Error, CustomStringConvertible {
    case timeout(String)
    case bluetooth(String)
    case protocolError(String)
    case cloud(String)
    case notPaired
    case usage(String)

    public var description: String {
        switch self {
        case .timeout(let what): return "Timed out: \(what)"
        case .bluetooth(let message), .protocolError(let message), .cloud(let message), .usage(let message):
            return message
        case .notPaired:
            return "No lamp credentials found. Run `morph pair` first."
        }
    }
}

public enum CharUUID {
    static let suffix = "-1C37-452D-8979-D1B4A787D0A4"
    /// Fragmented request/response channel for the handshake.
    public static let auth = "2DD10011" + suffix
    /// Attribute channel (daylight mode, presets). The only acknowledged channel.
    public static let attribute = "2DD10021" + suffix
    /// Colour temperature in Kelvin, uint16 LE.
    public static let colorTemp = "2DD11001" + suffix
    /// Power, 1 byte.
    public static let power = "2DD11005" + suffix
    /// Auto brightness, 1 byte.
    public static let autoBrightness = "2DD11006" + suffix
    /// Movement mode, 1 byte.
    public static let movement = "2DD11007" + suffix
    /// Brightness in lumens, uint16 LE.
    public static let brightnessLm = "2DD11009" + suffix
}

public enum MsgType {
    public static let reauthPayloadA: UInt8 = 0x06
    public static let reauthPayloadB: UInt8 = 0x07
    public static let reauthPayloadC: UInt8 = 0x08
    public static let requestProductInfo: UInt8 = 0x0A
    public static let productInfo: UInt8 = 0x0B
    public static let connectionEstablished: UInt8 = 0x26
    public static let attributeGet: UInt8 = 0x90
    public static let attributeValue: UInt8 = 0x91
    public static let attributeSet: UInt8 = 0x93
    public static let attributeAck: UInt8 = 0x94
    public static let attributeReport: UInt8 = 0x97
}

public enum Attribute {
    public static let daylight: UInt16 = 0x2013
}

public enum Preset: String, CaseIterable, Codable {
    case study, relax, precision

    public var attribute: UInt16 {
        switch self {
        case .study: return 0x201E
        case .relax: return 0x201F
        case .precision: return 0x2021
        }
    }
}

public enum Limits {
    public static let kelvin = 2700...6500
    public static let lumens = 100...1000
    /// The lamp discards a control write that arrives less than 100 ms after
    /// the previous one. 150 ms is the margin that the reference client uses.
    public static let minWriteGap: TimeInterval = 0.15
}

public func percentToLumens(_ percent: Int) -> Int {
    let clamped = Double(min(100, max(0, percent)))
    let range = Double(Limits.lumens.upperBound - Limits.lumens.lowerBound)
    return Int((Double(Limits.lumens.lowerBound) + clamped / 100 * range).rounded())
}

public func lumensToPercent(_ lumens: Int) -> Int {
    let clamped = Double(min(Limits.lumens.upperBound, max(Limits.lumens.lowerBound, lumens)))
    let range = Double(Limits.lumens.upperBound - Limits.lumens.lowerBound)
    return Int(((clamped - Double(Limits.lumens.lowerBound)) / range * 100).rounded())
}

public struct DysonMessage: Equatable {
    public let type: UInt8
    public let payload: Data
}

/// The MyDyson app assumes a 20-byte ATT payload and does not use the negotiated MTU.
public let fragmentCapacity = 20

/// Split a logical message into fragments.
///
/// The header of the first fragment is `0x80 | (total - 1)`. The header of each
/// subsequent fragment is its 0-based index. The type byte is part of the
/// payload stream, thus only the first fragment contains it.
public func fragmentMessage(type: UInt8, payload: Data = Data(), capacity: Int = fragmentCapacity) -> [Data] {
    let logical = Data([type]) + payload
    let perFragment = capacity - 1
    let total = max(1, (logical.count + perFragment - 1) / perFragment)
    return (0..<total).map { i in
        let chunk = logical.subdata(in: (i * perFragment)..<min(logical.count, (i + 1) * perFragment))
        let header = i == 0 ? UInt8(0x80 | (total - 1)) : UInt8(i & 0x7F)
        return Data([header]) + chunk
    }
}

/// `attribute(2) || length(2) || value`, little-endian, framed.
public func buildAttributeWrite(_ attribute: UInt16, value: Data) -> [Data] {
    fragmentMessage(type: MsgType.attributeSet, payload: le16(attribute) + le16(UInt16(value.count)) + value)
}

public func buildAttributeRead(_ attribute: UInt16) -> [Data] {
    fragmentMessage(type: MsgType.attributeGet, payload: le16(attribute))
}

public enum AttributeEvent: Equatable {
    /// Reply to a read. `value` is nil when the lamp refused the request.
    case value(attribute: UInt16, value: Data?)
    case ack(attribute: UInt16, status: UInt8)
    case report(attribute: UInt16, value: Data)
}

/// Decode one notification from the attribute channel.
///
/// A reply to a read contains a status byte that a report does not contain, so
/// the value is one byte further along.
public func decodeAttributeNotification(_ raw: Data) -> AttributeEvent? {
    let b = [UInt8](raw)
    guard b.count >= 5, b[0] & 0x80 != 0 else { return nil }
    let attribute = UInt16(b[2]) | UInt16(b[3]) << 8
    switch b[1] {
    case MsgType.attributeValue:
        guard b[4] == 0, b.count >= 8 else { return .value(attribute: attribute, value: nil) }
        return .value(attribute: attribute, value: Data(b[7...]))
    case MsgType.attributeAck:
        return .ack(attribute: attribute, status: b[4])
    case MsgType.attributeReport:
        guard b.count >= 7 else { return nil }
        return .report(attribute: attribute, value: Data(b[6...]))
    default:
        return nil
    }
}

/// Reassembles fragments that arrive as notifications on the auth channel.
///
/// The lamp sends unsolicited messages between handshake replies. A new first
/// fragment always restarts the buffer, so a stray fragment cannot block the stream.
public struct MessageAssembler {
    private var buffer = Data()
    private var type: UInt8 = 0
    private var expected = 0
    private var received = 0

    public init() {}

    public mutating func push(_ fragment: Data) -> DysonMessage? {
        let f = [UInt8](fragment)
        guard let header = f.first else { return nil }
        let body = f.dropFirst()

        if header & 0x80 != 0 {
            guard let first = body.first else { return nil }
            type = first
            expected = Int(header & 0x7F) + 1
            received = 1
            buffer = Data(body.dropFirst())
        } else {
            guard expected > 0 else { return nil }
            buffer.append(contentsOf: body)
            received = Int(header & 0x7F) + 1
        }

        guard received >= expected else { return nil }
        let message = DysonMessage(type: type, payload: buffer)
        self = MessageAssembler()
        return message
    }
}

public func le16(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8)])
}

public func readLE16(_ data: Data) -> Int? {
    let b = [UInt8](data)
    guard b.count >= 2 else { return nil }
    return Int(b[0]) | Int(b[1]) << 8
}
