import XCTest
@testable import GlassRailKit

/// Port of tests/direction.test.ts (9 cases), plus the override lapse the
/// native app adds on top.
///
/// Explicit UTC instants: the answer must depend on Eastern time, not on the
/// machine's zone. EDT is UTC-4; EST is UTC-5.
final class DirectionTests: XCTestCase {
    func edt(_ hhmm: String) -> Date { date("2026-08-03T\(hhmm):00.000Z") }
    func est(_ hhmm: String) -> Date { date("2026-01-15T\(hhmm):00.000Z") }

    // detectCommuteMode

    func testIsAmOvernightAndThroughTheMorningEastern() {
        XCTAssertEqual(Direction.detectCommuteMode(edt("04:00")), .am) // 12:00 AM ET
        XCTAssertEqual(Direction.detectCommuteMode(edt("10:30")), .am) // 6:30 AM ET
        XCTAssertEqual(Direction.detectCommuteMode(edt("15:59")), .am) // 11:59 AM ET
    }

    func testFlipsToPmAt2PMEasternExactly() {
        XCTAssertEqual(Direction.detectCommuteMode(edt("17:59")), .am) // 1:59 PM ET
        XCTAssertEqual(Direction.detectCommuteMode(edt("18:00")), .pm) // 2:00 PM ET
    }

    func testStaysPmThroughTheEvening() {
        XCTAssertEqual(Direction.detectCommuteMode(edt("21:30")), .pm) // 5:30 PM ET
        XCTAssertEqual(Direction.detectCommuteMode(edt("03:59")), .pm) // 11:59 PM ET (Aug 2)
    }

    func testUsesEasternTimeInWinterTooNotTheMachinesZone() {
        XCTAssertEqual(Direction.detectCommuteMode(est("18:59")), .am) // 1:59 PM ET
        XCTAssertEqual(Direction.detectCommuteMode(est("19:00")), .pm) // 2:00 PM ET
    }

    // resolveCommuteMode

    func testFollowsTheClockWhenTheRiderHasNotFlippedAnything() {
        XCTAssertEqual(Direction.resolveCommuteMode(edt("10:30"), override: nil), .am)
        XCTAssertEqual(Direction.resolveCommuteMode(edt("21:30"), override: nil), .pm)
    }

    func testHonoursAManualFlipWithinTheSameHalfOfTheDay() {
        let flip = ModeOverride(mode: .pm, at: edt("10:00"))
        XCTAssertEqual(Direction.resolveCommuteMode(edt("10:30"), override: flip), .pm)
        XCTAssertEqual(Direction.resolveCommuteMode(edt("15:00"), override: flip), .pm)
    }

    func testHandsControlBackToTheClockOnceItCrosses2PM() {
        let flip = ModeOverride(mode: .pm, at: edt("10:00"))
        XCTAssertEqual(Direction.resolveCommuteMode(edt("18:00"), override: flip), .pm)

        let back = ModeOverride(mode: .am, at: edt("21:00"))
        XCTAssertEqual(Direction.resolveCommuteMode(edt("21:30"), override: back), .am)
        XCTAssertEqual(Direction.resolveCommuteMode(edt("13:00"), override: back), .am)
    }

    func testAnAfternoonFlipToAmIsDroppedOnceTheClockIsBackInAm() {
        let back = ModeOverride(mode: .am, at: edt("21:00"))
        XCTAssertEqual(Direction.resolveCommuteMode(date("2026-08-04T13:00:00.000Z"), override: back), .am)
    }

    func testFailsSafelyOnAnUnparseableOverride() {
        // v4 stored `at` as a string; an unparseable one arrives here as nil.
        let bad = ModeOverride(mode: .pm, at: nil)
        XCTAssertEqual(Direction.resolveCommuteMode(edt("10:30"), override: bad), .am)
    }

    // Native additions (not in v4's suite)

    func testNextBoundaryIs2PMThenMidnightEastern() {
        XCTAssertEqual(Direction.nextBoundary(after: edt("13:00")), edt("18:00")) // 9 AM -> 2 PM
        XCTAssertEqual(Direction.nextBoundary(after: edt("18:00")), date("2026-08-04T04:00:00.000Z")) // 2 PM -> midnight
        XCTAssertEqual(Direction.nextBoundary(after: est("20:00")), date("2026-01-16T05:00:00.000Z")) // winter midnight
    }

    func testAMorningFlipLapsesAtTheNextBoundaryInsteadOfReturningTomorrow() {
        let flip = ModeOverride(mode: .pm, at: edt("13:00")) // 9 AM ET
        XCTAssertNotNil(Direction.effectiveOverride(flip, now: edt("15:00")))
        XCTAssertNil(Direction.effectiveOverride(flip, now: edt("18:00")))
        // The next morning the raw v4 rule would honour it again; the lapse doesn't.
        let nextMorning = date("2026-08-04T13:30:00.000Z")
        XCTAssertEqual(Direction.resolveCommuteMode(nextMorning, override: flip), .pm)
        XCTAssertEqual(Direction.resolveCommuteMode(nextMorning, override: Direction.effectiveOverride(flip, now: nextMorning)), .am)
    }
}
