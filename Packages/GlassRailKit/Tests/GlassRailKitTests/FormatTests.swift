import XCTest
@testable import GlassRailKit

/// Port of tests/format.test.ts (3 cases), plus the other formatters v4 used
/// without testing.
///
/// Times must render in Eastern time wherever the code runs (a rider visiting
/// California still wants New Jersey departure times).
final class FormatTests: XCTestCase {
    func testRendersEasternDaylightTimeNotTheHostsZone() {
        XCTAssertEqual(Format.time(date("2026-08-03T21:08:00.000Z")), "5:08 PM")
        XCTAssertEqual(Format.time(date("2026-08-03T13:51:00.000Z")), "9:51 AM")
    }

    func testRendersEasternStandardTimeInWinter() {
        XCTAssertEqual(Format.time(date("2026-01-15T21:08:00.000Z")), "4:08 PM")
    }

    func testHandlesMidnightAndNoonWithoutA0OClock() {
        XCTAssertEqual(Format.time(date("2026-08-03T04:00:00.000Z")), "12:00 AM")
        XCTAssertEqual(Format.time(date("2026-08-03T16:00:00.000Z")), "12:00 PM")
    }

    // Native additions

    func testCountdownMatchesV4() {
        let now = date("2026-08-03T13:00:00.000Z")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(-60), now: now), "Now")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(29), now: now), "Now") // rounds to 0
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(30), now: now), "in 1m") // JS rounds halves up
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(12 * 60), now: now), "in 12m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(65 * 60), now: now), "in 1h 5m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(120 * 60), now: now), "in 2h")
    }

    /// The Later sheet's "already left" rows, in the countdown's own terms.
    func testLeftAgoMirrorsTheCountdown() {
        let now = date("2026-08-03T13:00:00.000Z")
        XCTAssertEqual(Format.leftAgo(now.addingTimeInterval(60), now: now), "Just left") // clock skew
        XCTAssertEqual(Format.leftAgo(now.addingTimeInterval(-29), now: now), "Just left") // rounds to 0
        XCTAssertEqual(Format.leftAgo(now.addingTimeInterval(-30), now: now), "1m ago") // JS rounds halves up
        XCTAssertEqual(Format.leftAgo(now.addingTimeInterval(-12 * 60), now: now), "12m ago")
        XCTAssertEqual(Format.leftAgo(now.addingTimeInterval(-75 * 60), now: now), "1h 15m ago")
        XCTAssertEqual(Format.leftAgo(now.addingTimeInterval(-120 * 60), now: now), "2h ago")
    }

    func testFreshnessMatchesV4() {
        let now = date("2026-08-03T13:00:00.000Z")
        XCTAssertEqual(Format.freshness(generatedAt: now.addingTimeInterval(-12), now: now), "Fresh 12s ago")
        XCTAssertEqual(Format.freshness(generatedAt: now.addingTimeInterval(-50), now: now), "Updated 1m ago")
        XCTAssertEqual(Format.freshness(generatedAt: now.addingTimeInterval(-4 * 60), now: now), "Updated 4m ago")
        XCTAssertEqual(Format.freshness(generatedAt: now.addingTimeInterval(-2 * 3600), now: now), "Updated 2h ago")
        XCTAssertEqual(Format.freshness(generatedAt: now.addingTimeInterval(30), now: now), "Fresh 0s ago")
    }

    func testLabels() {
        XCTAssertEqual(Format.transferLabel(0), "Direct")
        XCTAssertEqual(Format.transferLabel(1), "1 transfer")
        XCTAssertEqual(Format.transferLabel(2), "2 transfers")
        XCTAssertEqual(Format.trackLabel("3"), "Track 3")
        XCTAssertEqual(Format.trackLabel(nil), "Track pending")
    }

    func testPositionLabel() {
        let t = date("2026-08-03T13:51:00.000Z")
        func stop(_ name: String, _ departed: Bool) -> TrainStop {
            TrainStop(name: name, time: t, departed: departed, status: nil, note: nil)
        }
        XCTAssertEqual(Format.positionLabel([]), "Stops")
        XCTAssertEqual(Format.positionLabel([stop("Montclair State U", false), stop("Hoboken", false)]), "Starts at Montclair State U · 9:51 AM")
        XCTAssertEqual(Format.positionLabel([stop("Bay Street", true), stop("Hoboken", false)]), "Past Bay Street · next Hoboken")
        XCTAssertEqual(Format.positionLabel([stop("Bay Street", true), stop("Hoboken", true)]), "Arrived at Hoboken")
    }
}
