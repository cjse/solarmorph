import XCTest
@testable import MorphCore

/// The line protocol between a client and the daemon, over a socket pair.
final class SocketTests: XCTestCase {
    var pair: [Int32] = [-1, -1]

    override func setUp() {
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    }

    override func tearDown() {
        pair.filter { $0 >= 0 }.forEach { close($0) }
    }

    func testLinesArriveOneByOne() {
        XCTAssertTrue(writeLine(Data("first".utf8), to: pair[0]))
        XCTAssertTrue(writeLine(Data("second".utf8), to: pair[0]))
        var reader = LineReader(pair[1])
        XCTAssertEqual(reader.next(), Data("first".utf8))
        XCTAssertEqual(reader.next(), Data("second".utf8))
    }

    func testEndOfConnectionIsNotATimeout() {
        close(pair[0])
        pair[0] = -1
        var reader = LineReader(pair[1])
        XCTAssertNil(reader.next())
        XCTAssertFalse(reader.timedOut)
    }

    func testTimeoutIsReported() {
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var reader = LineReader(pair[1])
        XCTAssertNil(reader.next())
        XCTAssertTrue(reader.timedOut)
    }

    func testPeerClosedDoesNotConsumeData() {
        XCTAssertFalse(peerClosed(pair[1]))
        XCTAssertTrue(writeLine(Data("reply".utf8), to: pair[0]))
        XCTAssertFalse(peerClosed(pair[1]))
        var reader = LineReader(pair[1])
        XCTAssertEqual(reader.next(), Data("reply".utf8))

        close(pair[0])
        pair[0] = -1
        XCTAssertTrue(peerClosed(pair[1]))
    }

    func testWriteToAClosedPeerFails() {
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        close(pair[1])
        pair[1] = -1
        XCTAssertFalse(writeLine(Data("lost".utf8), to: pair[0]))
    }

    func testRequestCarriesTheIdleLimit() throws {
        setenv("SOLARMORPH_IDLE", "300", 1)
        defer { unsetenv("SOLARMORPH_IDLE") }
        let request = try JSONDecoder().decode(DaemonRequest.self, from: JSONEncoder().encode(DaemonRequest(args: ["status"])))
        XCTAssertEqual(request.idle, 300)
        XCTAssertEqual(request.build, buildId)
    }

    func testBuildIdIsTheLinkerUUID() {
        XCTAssertNotNil(executableUUID())
    }
}
