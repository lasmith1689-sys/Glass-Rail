import XCTest
@testable import GlassRailKit

/// Port of tests/journey.test.ts (20 cases), and the connection checks since.
final class JourneyTests: XCTestCase {
    let now = date("2026-07-31T14:00:00.000Z")

    func iso(_ minsFromNow: Double) -> Date { now.addingTimeInterval(minsFromNow * 60) }

    func stop(_ name: String, _ minsFromNow: Double, _ departed: Bool) -> TrainStop {
        TrainStop(name: name, time: iso(minsFromNow), departed: departed, status: "OnTime", note: nil)
    }

    /// A Hoboken-bound run: origin-side stops already departed, Hoboken ahead.
    func hobokenRun() -> [TrainStop] {
        [
            stop("Upper Montclair", -20, true),
            stop("Watchung Avenue", -15, true),
            stop("Bay Street", -10, true),
            stop("Newark Broad Street", -2, true),
            stop("Hoboken", 18, false),
        ]
    }

    func withDeparted(_ stops: [TrainStop], _ departed: Bool) -> [TrainStop] {
        stops.map { var s = $0; s.departed = departed; return s }
    }

    // MARK: stopMatchesStation

    func testMatchesExactTerminalSuffixedAndReorderedStationNames() {
        XCTAssertTrue(Journey.stopMatchesStation("Watchung Avenue", watchungRef))
        XCTAssertTrue(Journey.stopMatchesStation("Hoboken", hobokenRef))
        XCTAssertTrue(Journey.stopMatchesStation("New York Penn Station", pennRef))
        XCTAssertTrue(Journey.stopMatchesStation("Penn Station New York", pennRef))
    }

    func testDoesNotMatchUnrelatedStops() {
        XCTAssertFalse(Journey.stopMatchesStation("Mountain Avenue", watchungRef))
        XCTAssertFalse(Journey.stopMatchesStation("Newark Broad Street", hobokenRef))
    }

    // MARK: Stop cursors

    func testFindsTheMostRecentDepartedAndTheNextStop() {
        let stops = hobokenRun()
        XCTAssertEqual(Journey.mostRecentDeparted(stops)?.name, "Newark Broad Street")
        XCTAssertEqual(Journey.nextStop(stops)?.name, "Hoboken")
        XCTAssertEqual(Journey.upcomingStops(stops).map(\.name), ["Hoboken"])
    }

    func testHandlesARunThatHasNotStarted() {
        let stops = withDeparted(hobokenRun(), false)
        XCTAssertNil(Journey.mostRecentDeparted(stops))
        XCTAssertEqual(Journey.nextStop(stops)?.name, "Upper Montclair")
        XCTAssertEqual(Journey.upcomingStops(stops).count, 5)
    }

    func testHandlesAFinishedRunAndAnEmptyList() {
        let stops = withDeparted(hobokenRun(), true)
        XCTAssertNil(Journey.nextStop(stops))
        XCTAssertEqual(Journey.upcomingStops(stops).count, 0)
        XCTAssertNil(Journey.mostRecentDeparted([]))
        XCTAssertNil(Journey.nextStop([]))
    }

    // MARK: journeyProgress

    func testIsZeroWhileTheTrainHasNotYetDepartedTheRidersOrigin() {
        XCTAssertEqual(Journey.journeyProgress(withDeparted(hobokenRun(), false), origin: watchungRef, dest: hobokenRef, now: now), 0)
    }

    func testInterpolatesBetweenTheLastDepartedStopAndTheNextOne() {
        // Departed Newark Broad (t=-2) heading to Hoboken (t=+18): train time
        // is now. Origin left at -15, destination at +18: 15/33 = 0.4545...
        let p = Journey.journeyProgress(hobokenRun(), origin: watchungRef, dest: hobokenRef, now: now)
        XCTAssertNotNil(p)
        XCTAssertGreaterThan(p ?? 0, 0.42)
        XCTAssertLessThan(p ?? 1, 0.49)
    }

    func testIsOneOnceTheDestinationStopHasDepartedOrArrived() {
        XCTAssertEqual(Journey.journeyProgress(withDeparted(hobokenRun(), true), origin: watchungRef, dest: hobokenRef, now: now), 1)
    }

    func testReturnsNilWhenOriginOrDestinationIsNotOnTheRun() {
        XCTAssertNil(Journey.journeyProgress(hobokenRun(), origin: pennRef, dest: hobokenRef, now: now))
        XCTAssertNil(Journey.journeyProgress(hobokenRun(), origin: watchungRef, dest: pennRef, now: now))
        XCTAssertNil(Journey.journeyProgress([], origin: watchungRef, dest: hobokenRef, now: now))
    }

    func testJourneyProgressFailsSafelyWhenStopTimesAreMissing() {
        let stops = hobokenRun().map { var s = $0; s.time = nil; return s }
        let p = Journey.journeyProgress(stops, origin: watchungRef, dest: hobokenRef, now: now)
        XCTAssertNotNil(p)
        XCTAssertGreaterThanOrEqual(p ?? -1, 0)
        XCTAssertLessThanOrEqual(p ?? 2, 1)
    }

    // MARK: scheduleProgress

    func testIsZeroBeforeDepartureLinearEnRouteOneAfterArrival() {
        XCTAssertEqual(Journey.scheduleProgress(departure: iso(10), arrival: iso(40), now: now), 0)
        XCTAssertEqual(Journey.scheduleProgress(departure: iso(-10), arrival: iso(30), now: now), 0.25, accuracy: 1e-5)
        XCTAssertEqual(Journey.scheduleProgress(departure: iso(-40), arrival: iso(-5), now: now), 1)
    }

    func testScheduleProgressFailsSafelyWithoutAnArrival() {
        XCTAssertEqual(Journey.scheduleProgress(departure: iso(-10), arrival: nil, now: now), 0)
    }

    // MARK: pickHero

    func makeView(_ trainId: String, _ depMins: Double) -> TripView {
        Status.deriveTripView(
            makeTrip(trainId: trainId, departure: iso(depMins), arrival: iso(depMins + 39), track: nil),
            changes: [:],
            alerts: true
        )
    }

    var views: [TripView] { [makeView("1074", 10), makeView("1078", 32)] }

    func testDefaultsToTheFirstUpcomingTrain() {
        XCTAssertEqual(Journey.pickHero(views, pinnedKey: nil)?.trip.trainId, "1074")
    }

    func testReturnsThePinnedTrainWhenItIsStillUpcoming() {
        XCTAssertEqual(Journey.pickHero(views, pinnedKey: "watchung|hoboken|1078")?.trip.trainId, "1078")
    }

    func testFallsBackToTheFirstTrainWhenThePinIsGone() {
        XCTAssertEqual(Journey.pickHero(views, pinnedKey: "watchung|hoboken|9999")?.trip.trainId, "1074")
        XCTAssertNil(Journey.pickHero([], pinnedKey: "watchung|hoboken|1078"))
    }

    // MARK: tripConnections

    var transferTrip: Trip {
        makeTrip(
            trainId: "1012",
            departure: iso(-15),
            arrival: iso(45),
            track: "2",
            transferCount: 1,
            transferAt: ["Newark Broad"],
            legTrainIds: ["1012", "6222"]
        )
    }

    func testReadsTheConnectionsLiveDepartureFromTheConnectingTrainsOwnRun() {
        let runs: Runs = [
            "6222": [
                stop("Dover", -40, true),
                stop("Newark Broad Street", 12, false),
                stop("Hoboken", 45, false),
            ],
        ]
        let conn = Journey.tripConnections(transferTrip, runs: runs).first
        XCTAssertEqual(conn?.station, "Newark Broad")
        XCTAssertEqual(conn?.trainId, "6222")
        XCTAssertEqual(conn?.departure, iso(12))
    }

    func testReportsTheConnectionWithoutATimeWhenItsRunIsNotLoaded() {
        let conn = Journey.tripConnections(transferTrip, runs: [:]).first
        XCTAssertEqual(conn?.trainId, "6222")
        XCTAssertNil(conn?.departure)
    }

    func testStillNamesTheTransferStationWhenTheLegTrainIdsAreMissing() {
        var noLegs = transferTrip
        noLegs.legTrainIds = nil
        let conn = Journey.tripConnections(noLegs, runs: [:]).first
        XCTAssertEqual(conn?.station, "Newark Broad")
        XCTAssertNil(conn?.trainId)
    }

    func testReturnsNothingForADirectTrip() {
        var direct = transferTrip
        direct.transferCount = 0
        direct.transferAt = []
        direct.legTrainIds = ["1012"]
        XCTAssertEqual(Journey.tripConnections(direct, runs: [:]).count, 0)
    }

    func testHandlesATwoTransferItineraryInOrder() {
        var twoStop = transferTrip
        twoStop.transferCount = 2
        twoStop.transferAt = ["Secaucus", "Newark Broad"]
        twoStop.legTrainIds = ["1012", "6222", "6631"]
        let conns = Journey.tripConnections(twoStop, runs: [:])
        XCTAssertEqual(conns.map(\.trainId), ["6222", "6631"])
        XCTAssertEqual(conns.map(\.station), ["Secaucus", "Newark Broad"])
    }

    // MARK: Connection risk

    /// `transferTrip`'s change at Newark Broad Street: its own train, 1012,
    /// due there `inMins` from now, and the connecting 6222 leaving `outMins`
    /// from now.
    func change(in inMins: Double, out outMins: Double, inDeparted: Bool = false, outDeparted: Bool = false) -> Connection? {
        let runs: Runs = [
            "1012": [
                stop("Watchung Avenue", -15, true),
                stop("Newark Broad Street", inMins, inDeparted),
                stop("Hoboken", inMins + 8, false),
            ],
            "6222": [
                stop("Dover", -40, true),
                stop("Newark Broad Street", outMins, outDeparted),
                stop("Hoboken", outMins + 33, false),
            ],
        ]
        return Journey.tripConnections(transferTrip, runs: runs).first
    }

    func testAConnectionLeavingBeforeTheRidersTrainGetsInIsMissed() {
        let conn = change(in: 14, out: 12)
        XCTAssertEqual(conn?.arrival, iso(14))
        XCTAssertEqual(conn?.risk, .missed)
        XCTAssertEqual(change(in: 13, out: 12)?.risk, .missed)
    }

    func testUnderTwoMinutesToChangeIsTight() {
        XCTAssertEqual(change(in: 11, out: 12)?.risk, .tight(minutes: 1))
        XCTAssertEqual(change(in: 12, out: 12)?.risk, .tight(minutes: 0))
        XCTAssertNil(change(in: 10, out: 12)?.risk)
    }

    func testAConnectionThatHasAlreadyLeftIsMissed() {
        // Gone is gone, whatever its time said.
        XCTAssertEqual(change(in: 8, out: 12, outDeparted: true)?.risk, .missed)
    }

    func testNothingToSayOnceTheRidersTrainHasBeenThroughTheStation() {
        XCTAssertNil(change(in: -1, out: 2, inDeparted: true)?.risk)
        XCTAssertNil(change(in: -1, out: -3, inDeparted: true, outDeparted: true)?.risk)
    }

    func testNothingToSayWithoutTheRidersOwnTrainsRun() {
        let runs: Runs = ["6222": [stop("Newark Broad Street", -2, true)]]
        let conn = Journey.tripConnections(transferTrip, runs: runs).first
        XCTAssertNil(conn?.arrival)
        XCTAssertEqual(conn?.departed, true)
        XCTAssertNil(conn?.risk)
    }

    func testTheFirstChangeFallsBackToTheTripsOwnTrainWhenTheLegsAreMissing() {
        var noLegs = transferTrip
        noLegs.legTrainIds = nil
        let runs: Runs = ["1012": [stop("Newark Broad Street", 14, false)]]
        let conn = Journey.tripConnections(noLegs, runs: runs).first
        XCTAssertEqual(conn?.arrival, iso(14))
        // No connecting train named, so nothing to measure against.
        XCTAssertNil(conn?.risk)
    }

    func testEachChangeIsJudgedOnTheTrainThatBringsTheRiderIn() {
        var twoStop = transferTrip
        twoStop.transferCount = 2
        twoStop.transferAt = ["Newark Broad", "Secaucus"]
        twoStop.legTrainIds = ["1012", "6222", "3840"]
        let runs: Runs = [
            "1012": [stop("Newark Broad Street", 5, false)],
            "6222": [stop("Newark Broad Street", 9, false), stop("Secaucus Upper Lvl", 20, false)],
            "3840": [stop("Secaucus Upper Lvl", 19, false)],
        ]
        let conns = Journey.tripConnections(twoStop, runs: runs)
        XCTAssertEqual(conns.map(\.arrival), [iso(5), iso(20)])
        XCTAssertEqual(conns.map(\.risk), [nil, .missed])
    }

    // MARK: nextConnection

    func testNamesTheTrainThatGetsTheRiderInSoonestAfterAMissedConnection() {
        let missed = change(in: 14, out: 12)!
        let runs: Runs = [
            "1012": [stop("Newark Broad Street", 14, false), stop("Hoboken", 22, false)],
            "6222": [stop("Newark Broad Street", 12, false), stop("Hoboken", 45, false)],
            // A minute after the rider's train: no time to change.
            "6224": [stop("Newark Broad Street", 15, false), stop("Hoboken", 40, false)],
            "6226": [stop("Newark Broad Street", 30, false), stop("Hoboken", 63, false)],
            // Leaves later and gets in sooner: the one to wait for.
            "6228": [stop("Newark Broad Street", 34, false), stop("Hoboken", 52, false)],
            // Calls at Newark Broad Street but never gets to Hoboken.
            "0412": [stop("Newark Broad Street", 20, false), stop("Dover", 80, false)],
            // Gets to Hoboken before it calls at Newark Broad Street.
            "1215": [stop("Hoboken", 16, false), stop("Newark Broad Street", 26, false)],
        ]
        XCTAssertEqual(
            Journey.nextConnection(after: missed, toward: hobokenRef, runs: runs),
            Connection.Onward(trainId: "6228", departure: iso(34), arrival: iso(52))
        )
    }

    func testNoTrainToWaitForUnlessTheConnectionIsMissed() {
        let runs: Runs = ["6226": [stop("Newark Broad Street", 30, false), stop("Hoboken", 63, false)]]
        XCTAssertNil(Journey.nextConnection(after: change(in: 11, out: 12)!, toward: hobokenRef, runs: runs))
        XCTAssertNil(Journey.nextConnection(after: change(in: 10, out: 12)!, toward: hobokenRef, runs: runs))
        XCTAssertEqual(Journey.nextConnection(after: change(in: 14, out: 12)!, toward: hobokenRef, runs: runs)?.trainId, "6226")
    }

    func testNeverWaitsForACancelledStopATrainThatHasLeftOrAnotherDaysTrain() {
        let missed = change(in: 14, out: 12)!
        let runs: Runs = [
            "6226": [
                TrainStop(name: "Newark Broad Street", time: iso(30), departed: false, status: "Cancelled", note: nil),
                stop("Hoboken", 63, false),
            ],
            "6228": [stop("Newark Broad Street", 34, true), stop("Hoboken", 52, false)],
            // Yesterday's and tomorrow's lists for trains of these numbers.
            "6230": [stop("Newark Broad Street", 30 - 24 * 60, true), stop("Hoboken", 63 - 24 * 60, true)],
            "6232": [stop("Newark Broad Street", 30 + 24 * 60, false), stop("Hoboken", 63 + 24 * 60, false)],
        ]
        XCTAssertNil(Journey.nextConnection(after: missed, toward: hobokenRef, runs: runs))
    }

    func testPicksTheSameTrainWhateverOrderTheRunsComeIn() {
        let missed = change(in: 14, out: 12)!
        // The same arrival: the earlier departure; the same both: the lower number.
        var runs: Runs = [
            "6240": [stop("Newark Broad Street", 30, false), stop("Hoboken", 63, false)],
            "6236": [stop("Newark Broad Street", 30, false), stop("Hoboken", 63, false)],
            "6238": [stop("Newark Broad Street", 28, false), stop("Hoboken", 63, false)],
        ]
        XCTAssertEqual(Journey.nextConnection(after: missed, toward: hobokenRef, runs: runs)?.trainId, "6238")
        runs["6238"] = nil
        XCTAssertEqual(Journey.nextConnection(after: missed, toward: hobokenRef, runs: runs)?.trainId, "6236")
    }
}
