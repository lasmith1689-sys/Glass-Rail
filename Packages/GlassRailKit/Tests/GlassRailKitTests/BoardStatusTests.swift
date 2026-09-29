import XCTest
@testable import GlassRailKit

/// Port of tests/status.test.ts (9 cases): parseBoardStatus.
final class BoardStatusTests: XCTestCase {
    func parse(_ status: String?, _ message: String?) -> TripStatus? {
        NJTParse.parseBoardStatus(status, message)
    }

    func testReturnsNilWhenTheBoardHasNothingToSay() {
        XCTAssertNil(parse(nil, nil))
        XCTAssertNil(parse("", ""))
        XCTAssertNil(parse(nil, nil)) // v4 also checked undefined, which is nil here too
    }

    func testDetectsCancellationsFromEitherField() {
        XCTAssertEqual(parse("CANCELLED", ""), .cancelled)
        XCTAssertEqual(parse("Cancelled", nil), .cancelled)
        XCTAssertEqual(parse("", "Train cancelled due to equipment"), .cancelled)
    }

    func testDetectsDelaysFromEitherField() {
        XCTAssertEqual(parse("DELAYED", ""), .delayed)
        XCTAssertEqual(parse("", "Running 15 min late"), .delayed)
        XCTAssertEqual(parse("Delayed 10 min", ""), .delayed)
    }

    func testCancellationWinsOverDelayWording() {
        XCTAssertEqual(parse("CANCELLED", "was delayed earlier"), .cancelled)
    }

    func testTreatsAnExplicitOnTimeClaimAsOnTime() {
        XCTAssertEqual(parse("OnTime", ""), .onTime)
        XCTAssertEqual(parse("ON TIME", ""), .onTime)
    }

    // NJ Transit shows a countdown or "All Aboard" for a train that is already
    // running late; the sign counts down to the actual departure.
    func testTreatsCountdownAndBoardingStatusesAsUnknownNotOnTime() {
        XCTAssertNil(parse("in 5 Min", ""))
        XCTAssertNil(parse("in 2 Min", ""))
        XCTAssertNil(parse("All Aboard", ""))
        XCTAssertNil(parse("Boarding", ""))
    }

    func testStillReadsAnExplicitDelayThatAccompaniesBoardingWording() {
        XCTAssertEqual(parse("All Aboard", "Delayed 6 min"), .delayed)
    }

    func testReturnsNilForUnrecognizedChatter() {
        XCTAssertNil(parse("", "Bike car open"))
    }

    func testStripsHTMLAndEntitiesBeforeMatching() {
        XCTAssertEqual(parse("<b>DELAYED</b>", ""), .delayed)
    }
}
