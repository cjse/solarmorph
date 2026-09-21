import XCTest
@testable import MorphCore

final class LiveStateTests: XCTestCase {
    let base = LampState(
        power: true, lumens: 200, brightness: 11, kelvin: 3000,
        autoBrightness: true, movement: false, daylight: true, preset: nil)

    func testCharacteristicValues() {
        var state = base
        XCTAssertTrue(state.apply(characteristic: CharUUID.brightnessLm, value: le16(550)))
        XCTAssertEqual(state.lumens, 550)
        XCTAssertEqual(state.brightness, 50)
        XCTAssertTrue(state.apply(characteristic: CharUUID.colorTemp, value: le16(4000)))
        XCTAssertEqual(state.kelvin, 4000)
        XCTAssertTrue(state.apply(characteristic: CharUUID.power, value: Data([0])))
        XCTAssertFalse(state.power)
    }

    func testTheSameValueIsNotAChange() {
        var state = base
        XCTAssertFalse(state.apply(characteristic: CharUUID.power, value: Data([1])))
        XCTAssertFalse(state.apply(characteristic: CharUUID.brightnessLm, value: le16(200)))
        XCTAssertFalse(state.apply(characteristic: CharUUID.auth, value: Data([9])))
        XCTAssertFalse(state.apply(characteristic: CharUUID.power, value: Data()))
        XCTAssertEqual(state, base)
    }

    func testPresetsAreExclusiveInAnySequence() {
        var state = base
        XCTAssertTrue(state.apply(attribute: Preset.study.attribute, value: Data([1])))
        XCTAssertEqual(state.preset, .study)

        // The lamp reports the new preset, then the old one as off.
        XCTAssertTrue(state.apply(attribute: Preset.relax.attribute, value: Data([1])))
        XCTAssertFalse(state.apply(attribute: Preset.study.attribute, value: Data([0])))
        XCTAssertEqual(state.preset, .relax)

        XCTAssertTrue(state.apply(attribute: Preset.relax.attribute, value: Data([0])))
        XCTAssertNil(state.preset)
    }

    func testDaylightAndUnknownAttributes() {
        var state = base
        XCTAssertTrue(state.apply(attribute: Attribute.daylight, value: Data([0])))
        XCTAssertEqual(state.daylight, false)
        XCTAssertFalse(state.apply(attribute: 0x2026, value: Data([1])))
    }

    func testFreshOption() throws {
        XCTAssertTrue(try LampCommand(arguments: ["status", "--fresh"]).fresh)
        XCTAssertFalse(try LampCommand(arguments: ["status"]).fresh)
        XCTAssertThrowsError(try LampCommand(arguments: ["on", "--fresh"]))
    }
}
