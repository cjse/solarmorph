import XCTest
@testable import MorphCore

/// Vectors from test/vectors.json in rummeyer/homebridge-dyson-solarcycle-morph,
/// which come from the Python reference implementation.
final class VectorTests: XCTestCase {
    let ltk = Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
    let nonce = Data(hex: "aabbccddeeff00112233445566778899")!
    let iv = Data(hex: "0f0e0d0c0b0a09080706050403020100")!
    let account = "12345678-90ab-cdef-1234-567890abcdef"
    let aesKey = Data(hex: "ff8e5a194e1eb570fa1712c7d0752250")!
    let sealed = "0f0e0d0c0b0a09080706050403020100e5fb49bdc36edb9798620d25c0910f396594c62aa297eef8ef082c075f7d099868409bc7ba2e504224a84129a4fa7edf"
    let payloadB = Data(hex: "00000f0e0d0c0b0a09080706050403020100e5fb49bdc36edb9798620d25c0910f39063316238fc371ded10f36fbacf8b02131955866bb6de02f4e73e1ea3ca74b07623b54597aadc1754c7339efd496b072")!
    let challenge = "11223344556677889900112233445566"

    func testKeyDerivation() {
        XCTAssertEqual(MorphCrypto.deriveAesKey(ltk: ltk), aesKey)
    }

    func testSeal() throws {
        XCTAssertEqual(try MorphCrypto.seal(key: aesKey, plaintext: nonce, iv: iv).hex, sealed)
    }

    func testPayloadA() throws {
        let a = try MorphCrypto.buildReauthPayloadA(accountId: account, key: aesKey, nonce: nonce, iv: iv)
        XCTAssertEqual(a.count, 82)
        XCTAssertEqual(a.hex, "1234567890abcdef1234567890abcdef0000" + sealed)
    }

    func testPayloadC() throws {
        let c = try MorphCrypto.buildReauthPayloadC(key: aesKey, challenge: nonce, iv: iv)
        XCTAssertEqual(c.count, 66)
        XCTAssertEqual(c.hex, "0000" + sealed)
    }

    func testPayloadB() throws {
        XCTAssertEqual(try MorphCrypto.parseReauthPayloadB(key: aesKey, payload: payloadB).hex, challenge)
    }

    func testPayloadBWithoutMac() throws {
        XCTAssertEqual(try MorphCrypto.parseReauthPayloadB(key: aesKey, payload: payloadB.prefix(50)).hex, challenge)
    }

    func testPayloadBRejectsWrongKey() {
        let wrong = Data(repeating: 1, count: 16)
        XCTAssertThrowsError(try MorphCrypto.parseReauthPayloadB(key: wrong, payload: payloadB))
    }

    func testFragments() throws {
        XCTAssertEqual(fragmentMessage(type: MsgType.requestProductInfo).map(\.hex), ["800a"])

        let a = try MorphCrypto.buildReauthPayloadA(accountId: account, key: aesKey, nonce: nonce, iv: iv)
        let fragments = fragmentMessage(type: MsgType.reauthPayloadA, payload: a)
        XCTAssertEqual(fragments.map(\.hex), [
            "84061234567890abcdef1234567890abcdef0000",
            "010f0e0d0c0b0a09080706050403020100e5fb49",
            "02bdc36edb9798620d25c0910f396594c62aa297",
            "03eef8ef082c075f7d099868409bc7ba2e504224",
            "04a84129a4fa7edf",
        ])

        var assembler = MessageAssembler()
        var message: DysonMessage?
        for fragment in fragments {
            message = assembler.push(fragment)
        }
        XCTAssertEqual(message, DysonMessage(type: MsgType.reauthPayloadA, payload: a))
    }

    func testAttributeFrames() {
        // From docs/PROTOCOL.md: daylight on, and the daylight question.
        XCTAssertEqual(buildAttributeWrite(Attribute.daylight, value: Data([1])).map(\.hex), ["80931320010001"])
        XCTAssertEqual(buildAttributeRead(Attribute.daylight).map(\.hex), ["80901320"])
    }

    func testAttributeDecode() {
        XCTAssertEqual(
            decodeAttributeNotification(Data(hex: "8091132000010001")!),
            .value(attribute: 0x2013, value: Data([1]))
        )
        XCTAssertEqual(
            decodeAttributeNotification(Data(hex: "80971320010000")!),
            .report(attribute: 0x2013, value: Data([0]))
        )
        XCTAssertEqual(
            decodeAttributeNotification(Data(hex: "8094132000")!),
            .ack(attribute: 0x2013, status: 0)
        )
    }

    func testScaling() {
        XCTAssertEqual(percentToLumens(0), 100)
        XCTAssertEqual(percentToLumens(100), 1000)
        XCTAssertEqual(percentToLumens(50), 550)
        XCTAssertEqual(lumensToPercent(550), 50)
    }
}
