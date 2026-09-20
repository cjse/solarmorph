import CommonCrypto
import CryptoKit
import Foundation

/// Cryptography for the LTK re-authentication handshake.
///
/// The key comes from the long-term key through HKDF-SHA256 (empty salt, first
/// 16 bytes). `seal` is unpadded AES-128-CBC followed by HMAC-SHA256 over the
/// ciphertext, with the same key for both.
public enum MorphCrypto {
    static let hkdfInfo = Data("USER_AUTH_AES".utf8) + Data([0, 0, 0])
    static let block = 16

    public static func deriveAesKey(ltk: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ltk),
            salt: Data(),
            info: hkdfInfo,
            outputByteCount: block
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// `IV(16) || ciphertext || HMAC-SHA256(ciphertext)(32)`
    public static func seal(key: Data, plaintext: Data, iv: Data = randomBytes(16)) throws -> Data {
        let ct = try aesCbc(kCCEncrypt, key: key, iv: iv, input: plaintext)
        return iv + ct + hmac(key: key, ct)
    }

    /// Re-auth PayloadA (type 0x06): `account GUID(16) || 00 00 || seal(nonce)`, 82 bytes.
    public static func buildReauthPayloadA(accountId: String, key: Data, nonce: Data = randomBytes(16), iv: Data = randomBytes(16)) throws -> Data {
        try uuidToBytes(accountId) + Data([0, 0]) + seal(key: key, plaintext: nonce, iv: iv)
    }

    /// Re-auth PayloadC (type 0x08): `00 00 || seal(challenge)`, 66 bytes.
    public static func buildReauthPayloadC(key: Data, challenge: Data, iv: Data = randomBytes(16)) throws -> Data {
        try Data([0, 0]) + seal(key: key, plaintext: challenge, iv: iv)
    }

    /// Get the challenge of the lamp from PayloadB (type 0x07, type byte removed).
    ///
    /// Layout: `00 00 || IV(16) || ciphertext(32) || MAC(32)?`. Some firmware
    /// does not send the MAC.
    public static func parseReauthPayloadB(key: Data, payload: Data) throws -> Data {
        let p = Data(payload)
        guard p.count >= 50 else {
            throw MorphError.protocolError("PayloadB is too short (\(p.count) bytes). The lamp probably rejected the handshake.")
        }
        let iv = p.subdata(in: 2..<18)
        let ct = p.subdata(in: 18..<50)
        if p.count >= 82 {
            let mac = p.subdata(in: 50..<82)
            guard mac == hmac(key: key, ct) else {
                throw MorphError.protocolError("PayloadB failed the HMAC check. The stored key is wrong.")
            }
        }
        let plain = try aesCbc(kCCDecrypt, key: key, iv: iv, input: ct)
        return plain.subdata(in: block..<(2 * block))
    }

    /// Dyson sends account GUIDs in big-endian (RFC 4122) byte order.
    public static func uuidToBytes(_ uuid: String) throws -> Data {
        guard let data = Data(hex: uuid.replacingOccurrences(of: "-", with: "")), data.count == 16 else {
            throw MorphError.protocolError("invalid account UUID: \(uuid)")
        }
        return data
    }

    public static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func hmac(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func aesCbc(_ operation: Int, key: Data, iv: Data, input: Data) throws -> Data {
        guard input.count % block == 0, key.count == block, iv.count == block else {
            throw MorphError.protocolError("AES input must be a multiple of \(block) bytes")
        }
        var output = Data(count: input.count + block)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(
                            CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), 0,
                            k.baseAddress, key.count, v.baseAddress,
                            inp.baseAddress, input.count,
                            out.baseAddress, capacity, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw MorphError.protocolError("AES failed with status \(status)")
        }
        return output.prefix(moved)
    }
}

public extension Data {
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
