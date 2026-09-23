import CoreBluetooth
import XCTest
@testable import MorphCore

/// The stuck-lamp error and the log that keeps its history.
final class RecoveryTests: XCTestCase {
    func testStuckLampErrors() {
        for code in [CBATTError.Code.attributeNotFound, .insufficientResources] {
            let error = NSError(domain: CBATTErrorDomain, code: code.rawValue)
            guard case .lampStuck = Lamp.failure("Subscription failed", error) else {
                return XCTFail("\(code) is not a stuck lamp")
            }
        }
    }

    func testOtherErrorsAreBluetoothErrors() {
        let other = NSError(domain: CBATTErrorDomain, code: CBATTError.Code.insufficientAuthentication.rawValue)
        guard case .bluetooth = Lamp.failure("Read failed", other) else { return XCTFail() }
        let sameCode = NSError(domain: NSPOSIXErrorDomain, code: CBATTError.Code.attributeNotFound.rawValue)
        guard case .bluetooth = Lamp.failure("Read failed", sameCode) else { return XCTFail() }
    }

    func testStuckLampIsNotAConnectionLoss() {
        // A connection loss gets one more connection. A stuck lamp must not.
        XCTAssertFalse(MorphError.lampStuck("test").isConnectionLoss)
        XCTAssertTrue(MorphError.lampStuck("test").description.contains("ten seconds"))
    }

    func testLogRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("daemon.log").path
        let old = log + ".1"

        XCTAssertFalse(rotateLog(log, to: old, limit: 10), "no log")
        try Data("small".utf8).write(to: URL(fileURLWithPath: log))
        XCTAssertFalse(rotateLog(log, to: old, limit: 10))
        try Data("larger than the limit".utf8).write(to: URL(fileURLWithPath: log))
        try Data("older".utf8).write(to: URL(fileURLWithPath: old))
        XCTAssertTrue(rotateLog(log, to: old, limit: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log))
        XCTAssertEqual(try String(contentsOfFile: old, encoding: .utf8), "larger than the limit")
    }

    func testStandardErrorIsNotAnotherFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        FileManager.default.createFile(atPath: file, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: file) }
        XCTAssertFalse(standardErrorIs(file))
        XCTAssertFalse(standardErrorIs(file + ".missing"))
    }
}
