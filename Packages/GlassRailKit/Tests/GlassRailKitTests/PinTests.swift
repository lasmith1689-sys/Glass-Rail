import XCTest
@testable import GlassRailKit

/// Port of tests/pin.test.ts (10 cases).
final class PinTests: XCTestCase {
    let now = date("2026-08-04T18:00:00.000Z")
    let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1012")

    var trip: Trip {
        makeTrip(
            trainId: "1012",
            departure: date("2026-08-04T14:12:00.000Z"),
            arrival: date("2026-08-04T15:20:00.000Z"),
            track: "2",
            transferCount: 1,
            transferAt: ["Newark Broad"]
        )
    }

    func testRoundTripsAPinTogetherWithTheTripItRefersTo() {
        let restored = PinStore.parse(PinStore.serialize(pin, trip: trip, now: now), now: now)
        XCTAssertEqual(restored?.dirKey, pin.dirKey)
        XCTAssertEqual(restored?.key, pin.key)
        XCTAssertEqual(restored?.trip, trip)
    }

    func testCarriesTheTripSoARelaunchMidRideCanStillDrawTheTrain() {
        let raw = PinStore.serialize(pin, trip: trip, now: now.addingTimeInterval(-40 * 60))
        XCTAssertEqual(PinStore.parse(raw, now: now)?.trip?.trainId, "1012")
    }

    func testSurvivesARelaunchWellPastTheLengthOfADelayedRide() {
        let raw = PinStore.serialize(pin, trip: trip, now: now.addingTimeInterval(-110 * 60))
        XCTAssertEqual(PinStore.parse(raw, now: now)?.key, pin.key)
    }

    func testKeepsAPinRightUpToTheTTLAndDropsItAfter() {
        let justInside = PinStore.serialize(pin, trip: trip, now: now.addingTimeInterval(-PinStore.ttl + 1))
        XCTAssertNotNil(PinStore.parse(justInside, now: now))
        let justOutside = PinStore.serialize(pin, trip: trip, now: now.addingTimeInterval(-PinStore.ttl - 1))
        XCTAssertNil(PinStore.parse(justOutside, now: now))
    }

    func testHoldsAPinForAtLeastTwoHours() {
        XCTAssertGreaterThanOrEqual(PinStore.ttl, 2 * 60 * 60)
    }

    func testAcceptsAPinWithNoStoredTrip() {
        let restored = PinStore.parse(PinStore.serialize(pin, trip: nil, now: now), now: now)
        XCTAssertEqual(restored?.key, pin.key)
        XCTAssertNil(restored?.trip)
    }

    func testDiscardsAStoredTripThatDoesNotMatchThePinnedKey() {
        var mismatched = trip
        mismatched.trainId = "9999"
        let object: [String: Any] = [
            "dirKey": pin.dirKey,
            "key": pin.key,
            "at": ISOTime.string(from: now),
            "trip": PinStore.tripJSONObject(mismatched),
        ]
        let raw = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)
        let restored = PinStore.parse(raw, now: now)
        XCTAssertEqual(restored?.key, pin.key)
        XCTAssertNil(restored?.trip)
    }

    func testDiscardsAStoredTripMissingTheFieldsTheBoardNeeds() {
        let raw = #"{"dirKey":"watchung|hoboken","key":"watchung|hoboken|1012","at":"2026-08-04T18:00:00.000Z","trip":{"trainId":"1012"}}"#
        XCTAssertNotNil(PinStore.parse(raw, now: now))
        XCTAssertNil(PinStore.parse(raw, now: now)?.trip)
    }

    func testFailsSafelyOnMissingMalformedOrIncompleteData() {
        XCTAssertNil(PinStore.parse(nil, now: now))
        XCTAssertNil(PinStore.parse("", now: now))
        XCTAssertNil(PinStore.parse("{not json", now: now))
        XCTAssertNil(PinStore.parse(#"{"dirKey":"a"}"#, now: now))
        XCTAssertNil(PinStore.parse(#"{"key":"a","at":"2026-08-04T18:00:00.000Z"}"#, now: now))
        XCTAssertNil(PinStore.parse(#"{"dirKey":"watchung|hoboken","key":"watchung|hoboken|1012","at":"not-a-date"}"#, now: now))
    }

    func testIgnoresAPinTimestampedInTheFutureClockSkew() {
        let raw = PinStore.serialize(pin, trip: trip, now: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(PinStore.parse(raw, now: now)?.key, pin.key)
    }
}
