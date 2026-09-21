import XCTest
@testable import MorphCore

final class CommandTests: XCTestCase {
    func testPowerCommandsSkipTheAttributes() throws {
        for name in ["on", "off", "toggle"] {
            XCTAssertFalse(try LampCommand(arguments: [name]).readsAttributes)
        }
        XCTAssertTrue(try LampCommand(arguments: ["status"]).readsAttributes)
    }

    func testSetOptions() throws {
        let command = try LampCommand(arguments: ["set", "--power", "on", "--brightness", "50", "--kelvin", "4000", "--preset", "none"])
        XCTAssertEqual(command.power, .on)
        XCTAssertEqual(command.lumens, 550)
        XCTAssertEqual(command.kelvin, 4000)
        guard case .clear? = command.preset else { return XCTFail("expected the preset to clear") }
    }

    func testLumensWinOverBrightness() throws {
        XCTAssertEqual(try LampCommand(arguments: ["set", "--brightness", "50", "--lumens", "300"]).lumens, 300)
    }

    func testUsageErrors() {
        XCTAssertThrowsError(try LampCommand(arguments: ["set", "--kelvin", "99"]))
        XCTAssertThrowsError(try LampCommand(arguments: ["set", "--kelvin"]))
        XCTAssertThrowsError(try LampCommand(arguments: ["set", "--colour", "red"]))
        XCTAssertThrowsError(try LampCommand(arguments: ["status", "extra"]))
        XCTAssertThrowsError(try LampCommand(arguments: ["dance"]))
    }

    func testReplyRoundTrip() throws {
        let reply = DaemonReply(failure: MorphError.notPaired)
        let decoded = try JSONDecoder().decode(DaemonReply.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(decoded.code, "notPaired")
        XCTAssertNil(decoded.state)
    }
}
