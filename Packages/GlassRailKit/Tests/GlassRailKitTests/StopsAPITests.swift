import XCTest
@testable import GlassRailKit

/// Port of tests/stops-api.test.ts (6 cases): parseTrainIds. v4 used it to
/// validate /api/stops?trains=; the app uses it to validate and cap the
/// stop-list batch it sends to NJ Transit.
final class StopsAPITests: XCTestCase {
    func testAcceptsACommaSeparatedListAndTrimsBlanks() {
        XCTAssertEqual(NJTParse.parseTrainIds("1074, 1078 ,1082"), ["1074", "1078", "1082"])
    }

    func testAcceptsASingleId() {
        XCTAssertEqual(NJTParse.parseTrainIds("1074"), ["1074"])
    }

    func testDedupesWhilePreservingOrder() {
        XCTAssertEqual(NJTParse.parseTrainIds("1074,1078,1074"), ["1074", "1078"])
    }

    func testDropsIdsThatAreNotPlausibleTrainNumbers() {
        XCTAssertEqual(NJTParse.parseTrainIds("1074,../etc,<script>,999999999"), ["1074"])
    }

    func testCapsTheBatchSoOneRequestCannotFanOutUnbounded() {
        let many = (0..<30).map { String(1000 + $0) }.joined(separator: ",")
        XCTAssertEqual(NJTParse.parseTrainIds(many).count, NJTQueries.maxStopListTrains)
    }

    func testReturnsAnEmptyListForMissingOrEmptyInput() {
        XCTAssertEqual(NJTParse.parseTrainIds(nil), [])
        XCTAssertEqual(NJTParse.parseTrainIds(""), [])
        XCTAssertEqual(NJTParse.parseTrainIds("   ,  "), [])
    }
}
