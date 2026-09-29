import XCTest
@testable import GlassRailKit

/// The Live Activity's lifecycle rules: phases, stale dates, dismissal.
final class RidePlanTests: XCTestCase {
    let departure = date("2026-08-03T13:57:00.000Z")
    var arrival: Date { departure.addingTimeInterval(39 * 60) }
    var plan: RidePlan { RidePlan(departure: departure, arrival: arrival) }

    func at(_ minutes: Double, from base: Date? = nil) -> Date {
        (base ?? departure).addingTimeInterval(minutes * 60)
    }

    func testPhasesRunPickupRidingArrived() {
        XCTAssertEqual(plan.phase(at: at(-10)), .pickup)
        XCTAssertEqual(plan.phase(at: at(-0.01)), .pickup)
        XCTAssertEqual(plan.phase(at: departure), .riding)
        XCTAssertEqual(plan.phase(at: at(20)), .riding)
        XCTAssertEqual(plan.phase(at: arrival), .arrived)
        XCTAssertEqual(plan.phase(at: at(2, from: arrival)), .arrived)
    }

    func testTheRideEndsThreeMinutesAfterArrivalLikeTheBoard() {
        XCTAssertEqual(plan.endsAt, arrival.addingTimeInterval(3 * 60))
        XCTAssertEqual(plan.endsAt, arrival.addingTimeInterval(Status.rideArrivalGrace))
        XCTAssertFalse(plan.isOver(at: at(2.9, from: arrival)))
        XCTAssertTrue(plan.isOver(at: at(3, from: arrival)))
    }

    func testWithoutAnArrivalTheRideIsBoundedAfterDeparture() {
        let open = RidePlan(departure: departure, arrival: nil)
        XCTAssertEqual(open.endsAt, departure.addingTimeInterval(Status.rideNoArrivalTTL))
        XCTAssertEqual(open.phase(at: at(60)), .riding)
        XCTAssertEqual(open.phase(at: open.endsAt), .arrived)
        XCTAssertNil(open.countdown(for: .riding, updatedAt: at(-5)))
    }

    func testAnArrivalBeforeTheDepartureIsTreatedAsUnknown() {
        let bad = RidePlan(departure: departure, arrival: at(-5))
        XCTAssertEqual(bad.endsAt, departure.addingTimeInterval(Status.rideNoArrivalTTL))
        XCTAssertEqual(bad.phase(at: at(1)), .riding)
        XCTAssertLessThan(bad.journey.lowerBound, bad.journey.upperBound)
    }

    func testStaleDateIsTheEndOfTheCurrentPhase() {
        XCTAssertEqual(plan.phaseEnds(at: at(-10)), departure)
        XCTAssertEqual(plan.phaseEnds(at: at(10)), arrival)
        XCTAssertEqual(plan.phaseEnds(at: at(1, from: arrival)), plan.endsAt)
    }

    func testAStaleRenderAdvancesOnePhase() {
        XCTAssertEqual(RidePlan.displayed(.pickup, isStale: false), .pickup)
        XCTAssertEqual(RidePlan.displayed(.pickup, isStale: true), .riding)
        XCTAssertEqual(RidePlan.displayed(.riding, isStale: false), .riding)
        XCTAssertEqual(RidePlan.displayed(.riding, isStale: true), .arrived)
        XCTAssertEqual(RidePlan.displayed(.arrived, isStale: true), .arrived)
        // Content made in each phase, marked stale at that phase's end, shows
        // the phase that is actually true then.
        for moment in [at(-10), at(10), at(1, from: arrival)] {
            let made = plan.phase(at: moment)
            let staleAt = plan.phaseEnds(at: moment)
            XCTAssertEqual(RidePlan.displayed(made, isStale: true), plan.phase(at: staleAt), "content made at \(moment)")
        }
    }

    func testBackgroundingDismissesWhenTheRideIsOver() {
        XCTAssertEqual(plan.dismissal(now: at(-30)), .after(plan.endsAt))
        XCTAssertEqual(plan.dismissal(now: at(20)), .after(arrival.addingTimeInterval(180)))
        XCTAssertEqual(plan.dismissal(now: plan.endsAt), .immediate)
        XCTAssertEqual(plan.dismissal(now: at(10, from: plan.endsAt)), .immediate)
    }

    func testCountdownsRunToThePickupThenToTheDropOff() {
        let madeAt = at(-12)
        XCTAssertEqual(plan.countdown(for: .pickup, updatedAt: madeAt), madeAt...departure)
        XCTAssertEqual(plan.countdown(for: .riding, updatedAt: madeAt), departure...arrival)
        XCTAssertNil(plan.countdown(for: .arrived, updatedAt: madeAt))
        // Content refreshed after the pickup time never produces a reversed range.
        XCTAssertEqual(plan.countdown(for: .pickup, updatedAt: at(2)), departure...departure)
    }

    func testJourneyBarSpansPickupToDropOff() {
        XCTAssertEqual(plan.journey, departure...arrival)
        let sameMinute = RidePlan(departure: departure, arrival: departure)
        XCTAssertEqual(sameMinute.journey, departure...at(1))
    }

    func testRangesNeverTrap() {
        XCTAssertEqual(RidePlan.range(arrival, departure), departure...arrival)
        XCTAssertEqual(RidePlan.range(departure, departure), departure...departure)
    }

    func testOnlyTheCurrentPinsUnfinishedRideIsKept() {
        let key = "watchung|hoboken|1074"
        XCTAssertTrue(RideActivityRules.shouldKeep(activityKey: key, pinKey: key, plan: plan, now: at(10)))
        XCTAssertFalse(RideActivityRules.shouldKeep(activityKey: key, pinKey: nil, plan: plan, now: at(10)), "released pin")
        XCTAssertFalse(RideActivityRules.shouldKeep(activityKey: key, pinKey: "watchung|hoboken|1078", plan: plan, now: at(10)), "another train pinned")
        XCTAssertFalse(RideActivityRules.shouldKeep(activityKey: key, pinKey: key, plan: plan, now: plan.endsAt), "ride over")
    }

    func testARideAcrossTheTwoPMSwitchStillEndsOnTime() {
        // Pinned 1:40 PM, arrives 2:19 PM: the board flips to the PM direction
        // mid-ride, but the activity's own dates still decide when it goes.
        let pickup = date("2026-08-03T17:40:00.000Z")
        let ride = RidePlan(departure: pickup, arrival: pickup.addingTimeInterval(39 * 60))
        XCTAssertEqual(Direction.detectCommuteMode(ride.endsAt), .pm)
        XCTAssertEqual(ride.dismissal(now: pickup.addingTimeInterval(-60)), .after(ride.endsAt))
        XCTAssertFalse(RideActivityRules.shouldKeep(activityKey: "k", pinKey: "k", plan: ride, now: ride.endsAt))
    }
}
