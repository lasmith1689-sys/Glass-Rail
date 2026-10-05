import XCTest
@testable import GlassRailKit

/// Port of tests/timing.test.ts (16 cases).
final class TimingTests: XCTestCase {
    /// EDT is UTC-4, so 9:51 AM ET is 13:51Z.
    func et(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").map { Int($0)! }
        return date(String(format: "2026-08-03T%02d:%02d:00.000Z", parts[0] + 4, parts[1]))
    }

    func stop(_ name: String, _ time: Date?, _ departed: Bool = false, _ status: String = "OnTime") -> TrainStop {
        TrainStop(name: name, time: time, departed: departed, status: status, note: nil)
    }

    /// Train 1074 exactly as NJ Transit served it on 2026-08-03 at 9:55 AM ET:
    /// scheduled out of Watchung Avenue at 9:51, running 6 minutes late, and
    /// expected to recover most of that by Hoboken.
    func run1074() -> [TrainStop] {
        [
            stop("Little Falls", et("9:37"), true),
            stop("Montclair State U", et("9:42"), true),
            stop("Montclair Heights", et("9:51"), true, "Late"),
            stop("Mountain Avenue", et("9:53"), true, "Late"),
            stop("Upper Montclair", et("9:55"), false, "Late"),
            stop("Watchung Avenue", et("9:57"), false, "Late"),
            stop("Walnut Street", et("10:00"), false, "Late"),
            stop("Bay Street", et("10:02"), false),
            stop("Newark Broad Street", et("10:14"), false),
            stop("Hoboken", et("10:32"), false),
        ]
    }

    var schedDep: Date { et("9:51") }
    var schedArr: Date { et("10:30") }

    func resolve(
        stops: [TrainStop]?? = nil,
        origin: StationRef = watchungRef,
        dest: StationRef = hobokenRef,
        scheduledArrival: Date?? = nil,
        textDelayMinutes: Int? = nil
    ) -> TripTiming {
        Timing.resolveTripTiming(
            stops: stops ?? run1074(),
            origin: origin,
            dest: dest,
            scheduledDeparture: schedDep,
            scheduledArrival: scheduledArrival ?? schedArr,
            textDelayMinutes: textDelayMinutes
        )
    }

    // MARK: The captured train 1074 case

    func testReportsTheTrue6MinutePickupDelayNJTsStatusStringHides() {
        let t = resolve()
        XCTAssertEqual(t.pickup.expected, et("9:57"))
        XCTAssertEqual(t.pickup.scheduled, schedDep)
        XCTAssertEqual(t.pickup.delayMinutes, 6)
        XCTAssertTrue(t.pickup.live)
    }

    func testReportsTheDropOffDelayIndependentlyNotByCopyingThePickupDelay() {
        let t = resolve()
        XCTAssertEqual(t.dropoff?.expected, et("10:32"))
        XCTAssertEqual(t.dropoff?.delayMinutes, 2)
        XCTAssertEqual(t.dropoff?.live, true)
        XCTAssertEqual(t.worstDelayMinutes, 6)
        XCTAssertTrue(t.late)
    }

    // MARK: Independence of the two legs

    func testADelayedPickupThatFullyRecoversShowsAnOnTimeDropOff() {
        let stops = run1074().map { $0.name == "Hoboken" ? stop("Hoboken", schedArr) : $0 }
        let t = resolve(stops: stops)
        XCTAssertEqual(t.pickup.delayMinutes, 6)
        XCTAssertEqual(t.dropoff?.delayMinutes, 0)
        XCTAssertEqual(t.worstDelayMinutes, 6)
    }

    func testAnOnTimePickupCanStillHaveALateDropOff() {
        let stops = run1074().map { s -> TrainStop in
            if s.name == "Watchung Avenue" { return stop("Watchung Avenue", schedDep) }
            if s.name == "Hoboken" { return stop("Hoboken", et("10:39")) }
            return s
        }
        let t = resolve(stops: stops)
        XCTAssertEqual(t.pickup.delayMinutes, 0)
        XCTAssertEqual(t.dropoff?.delayMinutes, 9)
        XCTAssertEqual(t.worstDelayMinutes, 9)
        XCTAssertTrue(t.late)
    }

    func testAnOnTimeRunReportsZeroDelayOnBothLegs() {
        let stops = run1074().map { s -> TrainStop in
            if s.name == "Watchung Avenue" { return stop("Watchung Avenue", schedDep) }
            if s.name == "Hoboken" { return stop("Hoboken", schedArr) }
            return s
        }
        let t = resolve(stops: stops)
        XCTAssertEqual(t.pickup.delayMinutes, 0)
        XCTAssertEqual(t.dropoff?.delayMinutes, 0)
        XCTAssertFalse(t.late)
    }

    func testNeverReportsNegativeLatenessWhenAStopTimeRunsEarly() {
        let stops = run1074().map { $0.name == "Watchung Avenue" ? stop("Watchung Avenue", et("9:48")) : $0 }
        let t = resolve(stops: stops)
        XCTAssertEqual(t.pickup.delayMinutes, 0)
        XCTAssertEqual(t.pickup.expected, et("9:48"))
    }

    // MARK: Fallbacks when live stop times are unavailable

    func testFallsBackToNJTsParsedDelayTextWhenThereIsNoStopList() {
        let t = resolve(stops: .some(nil), textDelayMinutes: 6)
        XCTAssertEqual(t.pickup.expected, et("9:57"))
        XCTAssertEqual(t.pickup.delayMinutes, 6)
        XCTAssertFalse(t.pickup.live)
        XCTAssertEqual(t.dropoff?.expected, et("10:36"))
        XCTAssertEqual(t.dropoff?.live, false)
    }

    func testFallsBackToTheScheduleWhenNothingIsKnown() {
        let t = resolve(stops: .some(nil))
        XCTAssertEqual(t.pickup.expected, schedDep)
        XCTAssertEqual(t.pickup.delayMinutes, 0)
        XCTAssertEqual(t.dropoff?.expected, schedArr)
        XCTAssertFalse(t.late)
    }

    func testIgnoresAStopListForADifferentRunOriginAbsent() {
        let t = resolve(stops: [stop("Summit", et("9:57"))], textDelayMinutes: 3)
        XCTAssertEqual(t.pickup.expected, et("9:54"))
        XCTAssertFalse(t.pickup.live)
    }

    func testKeepsALivePickupWhenTheDestinationIsOffThisTrainTransferTrip() {
        let t = resolve(dest: pennRef)
        XCTAssertEqual(t.pickup.delayMinutes, 6)
        XCTAssertTrue(t.pickup.live)
        XCTAssertEqual(t.dropoff?.live, false)
        XCTAssertEqual(t.dropoff?.delayMinutes, 6)
    }

    func testDoesNotMatchADestinationThatAppearsBeforeTheOrigin() {
        let t = resolve(origin: hobokenRef, dest: watchungRef)
        XCTAssertFalse(t.pickup.live)
        XCTAssertEqual(t.dropoff?.live, false)
    }

    // MARK: Boarding where the train starts

    /// Train 6263 as NJ Transit served it on 5 October 2026 at 4:52 PM ET:
    /// boarding at Penn Station, its first stop, for 4:52 (its board and the
    /// planner), while its stop list put Penn Station at 4:38.
    func run6263(departedPenn: Bool = false) -> [TrainStop] {
        [
            stop("New York Penn Station", et("16:38"), departedPenn, "BOARDING"),
            stop("Newark Broad Street", et("17:09")),
            stop("Watsessing Avenue", et("17:15")),
            stop("Bloomfield", et("17:18")),
            stop("Glen Ridge", et("17:20")),
            stop("Bay Street", et("17:23")),
            stop("Walnut Street", et("17:27")),
            stop("Watchung Avenue", et("17:29")),
            stop("Upper Montclair", et("17:32")),
        ]
    }

    func testABoardingTrainLeavesWhereItStartsAtItsTimeNotWhenBoardingBegan() {
        let boarding = Timing.resolveTripTiming(stops: run6263(), origin: pennRef, dest: watchungRef,
                                                scheduledDeparture: et("16:52"), scheduledArrival: et("17:30"))
        XCTAssertEqual(boarding.pickup.expected, et("16:52"))
        XCTAssertTrue(boarding.pickup.live)
        XCTAssertEqual(boarding.pickup.delayMinutes, 0)
        XCTAssertEqual(boarding.dropoff?.expected, et("17:29"), "its live arrival still counts")
        // Once it has left, its stop list's time is when it left.
        let gone = Timing.resolveTripTiming(stops: run6263(departedPenn: true), origin: pennRef, dest: watchungRef,
                                            scheduledDeparture: et("16:52"), scheduledArrival: et("17:30"))
        XCTAssertEqual(gone.pickup.expected, et("16:38"))
    }

    func testATrainRunningEarlyOnTheWayStillShowsItsEarlyTime() {
        // 1074 left Watchung Avenue at 9:50, due 9:51: not where it starts.
        let early = run1074().map { $0.name == "Watchung Avenue" ? stop("Watchung Avenue", et("9:50")) : $0 }
        XCTAssertEqual(resolve(stops: early).pickup.expected, et("9:50"))
        XCTAssertTrue(resolve(stops: early).pickup.live)
    }

    func testSkipsStopsWhoseTimeCouldNotBeParsed() {
        let stops = run1074().map { $0.name == "Watchung Avenue" ? stop("Watchung Avenue", nil) : $0 }
        let t = resolve(stops: stops)
        XCTAssertFalse(t.pickup.live)
        XCTAssertEqual(t.pickup.expected, schedDep)
        XCTAssertEqual(t.dropoff?.live, true)
    }

    func testTakesTheDropOffFromTheLiveRunWhenTheTripHasNoScheduledArrival() {
        // A trip read off a departure board has no timetable arrival.
        let t = resolve(scheduledArrival: .some(nil))
        XCTAssertEqual(t.dropoff?.expected, et("10:32"))
        XCTAssertEqual(t.dropoff?.live, true)
        XCTAssertEqual(t.dropoff?.delayMinutes, 0)
        XCTAssertEqual(t.worstDelayMinutes, 6)
        // With no live run there is nothing to show.
        XCTAssertNil(resolve(stops: .some(nil), scheduledArrival: .some(nil)).dropoff)
    }

    // MARK: withTiming

    var trip: Trip {
        makeTrip(trainId: "1074", departure: schedDep, arrival: schedArr, track: "2")
    }

    func testOverridesTheViewsExpectedTimesAndMarksItDelayed() {
        let base = Status.deriveTripView(trip, changes: [:], alerts: true)
        XCTAssertFalse(base.delayed)
        let view = Timing.withTiming(base, resolve())
        XCTAssertEqual(view.expectedDeparture, et("9:57"))
        XCTAssertEqual(view.expectedArrival, et("10:32"))
        XCTAssertTrue(view.delayed)
        XCTAssertEqual(view.delayMinutes, 6)
        XCTAssertEqual(view.timing?.dropoff?.delayMinutes, 2)
    }

    func testLeavesAnOnTimeViewUntouched() {
        let base = Status.deriveTripView(trip, changes: [:], alerts: true)
        let view = Timing.withTiming(base, resolve(stops: .some(nil)))
        XCTAssertEqual(view.expectedDeparture, schedDep)
        XCTAssertFalse(view.delayed)
        XCTAssertNil(view.delayMinutes)
    }

    func testKeepsACancellationVisibleEvenWhenTimingLooksFine() {
        var cancelled = trip
        cancelled.status = .cancelled
        cancelled.statusNote = "Cancelled"
        let base = Status.deriveTripView(cancelled, changes: [:], alerts: true)
        let view = Timing.withTiming(base, resolve(stops: .some(nil)))
        XCTAssertTrue(view.cancelled)
    }

    // MARK: Native addition: the 90-minute sanity window

    func testIgnoresAStopTimeMoreThan90MinutesFromSchedule() {
        let stops = run1074().map { $0.name == "Watchung Avenue" ? stop("Watchung Avenue", et("11:30")) : $0 }
        let t = resolve(stops: stops)
        XCTAssertFalse(t.pickup.live)
        XCTAssertEqual(t.pickup.expected, schedDep)
    }

    func testIgnoresAStopListThatEndsAtTheOrigin() {
        let stops = Array(run1074().prefix(6)) // ends at Watchung Avenue
        let t = resolve(stops: stops)
        XCTAssertFalse(t.pickup.live)
        XCTAssertEqual(t.dropoff?.live, false)
    }
}
