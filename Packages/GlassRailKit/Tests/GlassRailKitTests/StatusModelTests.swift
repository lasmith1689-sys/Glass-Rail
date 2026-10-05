import XCTest
@testable import GlassRailKit

/// Port of tests/status-model.test.ts (40 cases).
final class StatusModelTests: XCTestCase {
    let now = date("2026-07-31T13:00:00.000Z")
    let noChanges: [String: TrackChange] = [:]

    func iso(_ minsFromNow: Double) -> Date { now.addingTimeInterval(minsFromNow * 60) }

    func trip(
        trainId: String? = "1074",
        fromId: String = "watchung",
        toId: String = "hoboken",
        departure: Date? = nil,
        arrival: Date?? = nil,
        track: String?? = nil,
        transferCount: Int = 0,
        transferAt: [String] = [],
        status: TripStatus? = nil,
        statusNote: String? = nil
    ) -> Trip {
        makeTrip(
            fromId: fromId,
            toId: toId,
            trainId: trainId,
            departure: departure ?? iso(40),
            arrival: arrival ?? iso(75),
            track: track ?? "2",
            transferCount: transferCount,
            transferAt: transferAt,
            status: status,
            statusNote: statusNote
        )
    }

    // MARK: parseDelayMinutes

    func testExtractsMinutesFromNJTDelayWording() {
        XCTAssertEqual(Status.parseDelayMinutes("Delayed 10 min"), 10)
        XCTAssertEqual(Status.parseDelayMinutes("Running 15 min late"), 15)
        XCTAssertEqual(Status.parseDelayMinutes("DELAYED 6 MIN"), 6)
    }

    func testParseDelayFailsSafelyOnMissingOrUnparseableNotes() {
        XCTAssertNil(Status.parseDelayMinutes(nil))
        XCTAssertNil(Status.parseDelayMinutes(""))
        XCTAssertNil(Status.parseDelayMinutes("Delayed"))
        XCTAssertNil(Status.parseDelayMinutes("Track change at Newark"))
    }

    func testIgnoresAbsurdDelayValues() {
        XCTAssertNil(Status.parseDelayMinutes("Delayed 0 min"))
        XCTAssertNil(Status.parseDelayMinutes("Delayed 999 min"))
    }

    // MARK: shiftIso

    func testShiftsATimestampForwardByMinutes() {
        XCTAssertEqual(Status.shift(iso(10), minutes: 6), iso(16))
    }

    func testShiftPassesThroughWhenThereIsNothingToShift() {
        XCTAssertNil(Status.shift(nil, minutes: 6))
        XCTAssertEqual(Status.shift(iso(10), minutes: nil), iso(10))
    }

    // MARK: deriveFeedMode

    func testReportsLiveForAFreshLivePayload() {
        XCTAssertEqual(Status.deriveFeedMode(kind: .live, generatedAt: iso(-1), now: now), .live)
    }

    func testDowngradesAStaleLivePayload() {
        let old = now.addingTimeInterval(-Status.staleAfter - 1)
        XCTAssertEqual(Status.deriveFeedMode(kind: .live, generatedAt: old, now: now), .stale)
    }

    func testSampleDataIsAlwaysSampleNeverLiveEvenWhenFresh() {
        XCTAssertEqual(Status.deriveFeedMode(kind: .sample, generatedAt: iso(0), now: now), .sample)
        XCTAssertEqual(Status.deriveFeedMode(kind: .sample, generatedAt: iso(-60), now: now), .sample)
    }

    func testRepeatedFetchFailuresDowngradeAnOtherwiseFreshLivePayload() {
        XCTAssertEqual(Status.deriveFeedMode(kind: .live, generatedAt: iso(-1), now: now, consecutiveFailures: 1), .live)
        XCTAssertEqual(Status.deriveFeedMode(kind: .live, generatedAt: iso(-1), now: now, consecutiveFailures: 2), .stale)
    }

    func testAnUnparseableGeneratedAtIsNeverPresentedAsLive() {
        XCTAssertEqual(Status.deriveFeedMode(kind: .live, generatedAt: nil, now: now), .stale)
    }

    // MARK: deriveTripView

    func testAnOnTimeTripHasNoDelayAndKeepsItsScheduledTimes() {
        let t = trip(status: .onTime)
        let view = Status.deriveTripView(t, changes: noChanges, alerts: true)
        XCTAssertFalse(view.delayed)
        XCTAssertNil(view.delayMinutes)
        XCTAssertEqual(view.expectedDeparture, t.departure)
        XCTAssertEqual(view.expectedArrival, t.arrival)
        XCTAssertNil(view.trackChange)
        XCTAssertFalse(view.cancelled)
    }

    func testComputesTheExpectedDepartureAndArrivalFromTheDelayNote() {
        let view = Status.deriveTripView(trip(status: .delayed, statusNote: "Delayed 6 min"), changes: noChanges, alerts: true)
        XCTAssertTrue(view.delayed)
        XCTAssertEqual(view.delayMinutes, 6)
        XCTAssertEqual(view.expectedDeparture, iso(46))
        XCTAssertEqual(view.expectedArrival, iso(81))
    }

    func testStaysDelayedWithScheduledTimesWhenTheNoteHasNoMinutes() {
        let t = trip(status: .delayed, statusNote: nil)
        let view = Status.deriveTripView(t, changes: noChanges, alerts: true)
        XCTAssertTrue(view.delayed)
        XCTAssertNil(view.delayMinutes)
        XCTAssertEqual(view.expectedDeparture, t.departure)
        XCTAssertEqual(view.expectedArrival, t.arrival)
    }

    func testHandlesADelayedTripWithNoArrival() {
        let view = Status.deriveTripView(trip(arrival: .some(nil), status: .delayed, statusNote: "Delayed 6 min"), changes: noChanges, alerts: true)
        XCTAssertNil(view.expectedArrival)
    }

    func testSuppressesDelayAndTrackChangeStateWhenAlertsAreOff() {
        let changes = ["watchung|hoboken|1074": TrackChange(from: "2", to: "3", detectedAt: now)]
        let t = trip(status: .delayed, statusNote: "Delayed 6 min")
        let view = Status.deriveTripView(t, changes: changes, alerts: false)
        XCTAssertFalse(view.delayed)
        XCTAssertNil(view.delayMinutes)
        XCTAssertEqual(view.expectedDeparture, t.departure)
        XCTAssertNil(view.trackChange)
    }

    func testDelayAndTrackChangeCanCoexistOnOneTrip() {
        let changes = ["watchung|hoboken|1074": TrackChange(from: "2", to: "3", detectedAt: now)]
        let view = Status.deriveTripView(trip(track: "3", status: .delayed, statusNote: "Delayed 6 min"), changes: changes, alerts: true)
        XCTAssertTrue(view.delayed)
        XCTAssertEqual(view.delayMinutes, 6)
        XCTAssertEqual(view.trackChange, TrackChange(from: "2", to: "3", detectedAt: now))
    }

    // MARK: updateTrackHistory

    func testFirstSuccessfulFetchNeverReportsAChange() {
        let result = Status.updateTrackHistory([:], trips: [trip(track: "2")], now: now)
        XCTAssertEqual(result.changes.count, 0)
        XCTAssertEqual(result.history["watchung|hoboken|1074"], "2")
    }

    func testDetectsTheSameTrainMovingFromTrack2ToTrack3() {
        let first = Status.updateTrackHistory([:], trips: [trip(track: "2")], now: now)
        let second = Status.updateTrackHistory(first.history, trips: [trip(track: "3")], now: now)
        XCTAssertEqual(second.changes["watchung|hoboken|1074"], TrackChange(from: "2", to: "3", detectedAt: now))
        XCTAssertEqual(second.history["watchung|hoboken|1074"], "3")
    }

    func testANewTrainOnTrack3DoesNotInheritThePriorTrainsChange() {
        let first = Status.updateTrackHistory([:], trips: [trip(trainId: "1074", track: "2")], now: now)
        let second = Status.updateTrackHistory(first.history, trips: [trip(trainId: "1078", track: "3")], now: now)
        XCTAssertEqual(second.changes.count, 0)
    }

    func testSameTrackOnRefetchReportsNoChange() {
        let first = Status.updateTrackHistory([:], trips: [trip(track: "2")], now: now)
        let second = Status.updateTrackHistory(first.history, trips: [trip(track: "2")], now: now)
        XCTAssertEqual(second.changes.count, 0)
    }

    func testATemporarilyMissingTrackNeitherReportsAChangeNorForgetsTheLastShownTrack() {
        let first = Status.updateTrackHistory([:], trips: [trip(track: "2")], now: now)
        let second = Status.updateTrackHistory(first.history, trips: [trip(track: .some(nil))], now: now)
        XCTAssertEqual(second.changes.count, 0)
        XCTAssertEqual(second.history["watchung|hoboken|1074"], "2")
        let third = Status.updateTrackHistory(second.history, trips: [trip(track: "3")], now: now)
        XCTAssertEqual(third.changes["watchung|hoboken|1074"]?.from, "2")
    }

    func testTripsWithoutATrainIdAreIgnoredSafely() {
        let result = Status.updateTrackHistory([:], trips: [trip(trainId: nil, track: "4")], now: now)
        XCTAssertEqual(result.history.count, 0)
        XCTAssertEqual(result.changes.count, 0)
    }

    // MARK: pruneTrackChanges

    func testKeepsRecentChangesAndDropsExpiredOnes() {
        let fresh = TrackChange(from: "2", to: "3", detectedAt: iso(-2))
        let expired = TrackChange(from: "1", to: "4", detectedAt: now.addingTimeInterval(-Status.trackChangeTTL - 1))
        let pruned = Status.pruneTrackChanges(["a": fresh, "b": expired], now: now)
        XCTAssertNotNil(pruned["a"])
        XCTAssertNil(pruned["b"])
    }

    // MARK: selectTripViews

    func testADepartedTrainIsDroppedAndTheNextValidDepartureBecomesTheHead() {
        let departed = trip(trainId: "1074", departure: now.addingTimeInterval(-Status.departureGrace - 1))
        let upcoming = trip(trainId: "1078", departure: iso(22))
        let views = Status.selectTripViews([departed, upcoming], fromId: "watchung", toId: "hoboken", now: now, alerts: true, changes: noChanges)
        XCTAssertEqual(views.first?.trip.trainId, "1078")
        XCTAssertEqual(views.count, 1)
    }

    func testADelayedTrainIsKeptWhileItsExpectedDepartureIsStillAhead() {
        let delayed = trip(trainId: "1074", departure: iso(-5), status: .delayed, statusNote: "Delayed 20 min")
        let views = Status.selectTripViews([delayed], fromId: "watchung", toId: "hoboken", now: now, alerts: true, changes: noChanges)
        XCTAssertEqual(views.count, 1)
        XCTAssertEqual(views.first?.expectedDeparture, iso(15))
    }

    func testOrdersByExpectedDepartureSoAHeavyDelayYieldsTheHeroToTheNextTrain() {
        let delayed = trip(trainId: "1074", departure: iso(5), status: .delayed, statusNote: "Delayed 30 min")
        let onTime = trip(trainId: "1078", departure: iso(12))
        let views = Status.selectTripViews([delayed, onTime], fromId: "watchung", toId: "hoboken", now: now, alerts: true, changes: noChanges)
        XCTAssertEqual(views.map { $0.trip.trainId }, ["1078", "1074"])
    }

    func testFiltersToTheRequestedDirectionOnly() {
        let views = Status.selectTripViews(
            [trip(fromId: "hoboken", toId: "watchung"), trip(trainId: "1078")],
            fromId: "watchung", toId: "hoboken", now: now, alerts: true, changes: noChanges
        )
        XCTAssertEqual(views.count, 1)
        XCTAssertEqual(views.first?.trip.trainId, "1078")
    }

    // MARK: detectDeparture

    var previousHead: Status.HeroSnapshot {
        Status.HeroSnapshot(key: "watchung|hoboken|1074", label: "1074", effectiveDeparture: iso(-3))
    }

    func testAnnouncesWhenThePreviousHeadsTimeHasPassedAndItLeftTheList() {
        XCTAssertEqual(Status.detectDeparture(previousHead, currentKeys: ["watchung|hoboken|1078"], now: now), "1074")
    }

    func testStaysQuietWhenThePreviousHeadIsStillListed() {
        XCTAssertNil(Status.detectDeparture(previousHead, currentKeys: ["watchung|hoboken|1074", "watchung|hoboken|1078"], now: now))
    }

    func testStaysQuietWhenTheTrainVanishedButItsDepartureIsStillInTheFuture() {
        var future = previousHead
        future.effectiveDeparture = iso(10)
        XCTAssertNil(Status.detectDeparture(future, currentKeys: ["watchung|hoboken|1078"], now: now))
    }

    func testStaysQuietWithNoPreviousHead() {
        XCTAssertNil(Status.detectDeparture(nil, currentKeys: ["watchung|hoboken|1078"], now: now))
    }

    // MARK: retainRideTrip

    let rideKey = "watchung|hoboken|1074"

    func testPrefersTheTripTheFeedIsStillServing() {
        let riding = trip(trainId: "1074", departure: iso(-12))
        let other = trip(trainId: "1078", departure: iso(22))
        let stale = trip(trainId: "1074", departure: iso(-30))
        XCTAssertEqual(Status.retainRideTrip(cached: stale, trips: [riding, other], key: rideKey), riding)
    }

    func testFallsBackToTheLastSeenTripOnceThePlannerDropsIt() {
        let riding = trip(trainId: "1074", departure: iso(-12))
        let other = trip(trainId: "1078", departure: iso(22))
        XCTAssertEqual(Status.retainRideTrip(cached: riding, trips: [other], key: rideKey), riding)
    }

    func testDoesNotResurrectACachedTripForADifferentTrain() {
        let wrong = trip(trainId: "9999", departure: iso(-12))
        let other = trip(trainId: "1078", departure: iso(22))
        XCTAssertNil(Status.retainRideTrip(cached: wrong, trips: [other], key: rideKey))
    }

    func testReturnsNilWhenThereIsNothingToShow() {
        let other = trip(trainId: "1078", departure: iso(22))
        XCTAssertNil(Status.retainRideTrip(cached: nil, trips: [other], key: rideKey))
        XCTAssertNil(Status.retainRideTrip(cached: nil, trips: [], key: rideKey))
    }

    // MARK: rideView

    func testKeepsADepartedTrainWhileItIsStillEnRouteWithItsDelay() {
        let t = trip(trainId: "1074", departure: iso(-12), arrival: iso(27), status: .delayed, statusNote: "Delayed 5 min")
        let view = Status.rideView(t, now: now, alerts: true, changes: noChanges)
        XCTAssertEqual(view?.trip.trainId, "1074")
        XCTAssertEqual(view?.delayMinutes, 5)
    }

    func testLetsGoShortlyAfterTheExpectedArrival() {
        let arrived = trip(trainId: "1074", departure: iso(-60), arrival: now.addingTimeInterval(-Status.rideArrivalGrace - 1))
        XCTAssertNil(Status.rideView(arrived, now: now, alerts: true, changes: noChanges))
    }

    func testHoldsATripWithNoArrivalForABoundedWindowOnly() {
        XCTAssertNotNil(Status.rideView(trip(departure: iso(-12), arrival: .some(nil)), now: now, alerts: true, changes: noChanges))
        XCTAssertNil(Status.rideView(trip(departure: iso(-120), arrival: .some(nil)), now: now, alerts: true, changes: noChanges))
    }

    func testCoversTheWholeJourneyOfATransferTripNotJustTheFirstLeg() {
        let transfer = trip(trainId: "1012", departure: iso(-15), arrival: iso(45), transferCount: 1, transferAt: ["Newark Broad"])
        XCTAssertEqual(Status.rideView(transfer, now: now, alerts: true, changes: noChanges)?.trip.trainId, "1012")
    }

    // MARK: hidingDominatedConnections

    func homeViews(_ trips: [Trip]) -> [TripView] {
        Status.selectTripViews(trips, fromId: "hoboken", toId: "watchung", now: now, alerts: true, changes: noChanges)
    }

    func home(_ train: String, leaves: Double, arrives: Double, via: [String] = [], status: TripStatus? = nil) -> Trip {
        trip(trainId: train, fromId: "hoboken", toId: "watchung", departure: iso(leaves), arrival: iso(arrives),
             transferCount: via.count, transferAt: via, status: status)
    }

    func testHidesAConnectionThatALaterTripBeats() {
        // Three ways to the same arrival: only the latest is worth taking, and
        // the earliest also loses to a direct train that gets there sooner.
        let views = homeViews([
            home("59", leaves: 14, arrives: 83, via: ["Secaucus"]),
            home("1635", leaves: 17, arrives: 83, via: ["Secaucus"]),
            home("657", leaves: 38, arrives: 83, via: ["Newark Broad"]),
            home("1011", leaves: 33, arrives: 69),
        ])
        XCTAssertEqual(Status.hidingDominatedConnections(views).map(\.trip.trainId), ["1011", "657"])
    }

    func testNeverHidesADirectTrainThePinnedTripOrForACancelledOne() {
        let fast = home("881", leaves: 15, arrives: 60, via: ["Newark Broad"])
        // A direct train stays even when a later connection gets there first.
        let slowDirect = home("1009", leaves: 10, arrives: 80)
        XCTAssertEqual(Status.hidingDominatedConnections(homeViews([slowDirect, fast])).map(\.trip.trainId), ["1009", "881"])

        // The pinned connection stays even when beaten.
        let beaten = home("433", leaves: 5, arrives: 90, via: ["Newark Broad"])
        XCTAssertEqual(Status.hidingDominatedConnections(homeViews([beaten, fast])).map(\.trip.trainId), ["881"])
        XCTAssertEqual(Status.hidingDominatedConnections(homeViews([beaten, fast]), keeping: "hoboken|watchung|433").map(\.trip.trainId), ["433", "881"])

        // A cancelled train is no better option.
        let cancelled = home("339", leaves: 20, arrives: 60, status: .cancelled)
        XCTAssertEqual(Status.hidingDominatedConnections(homeViews([beaten, cancelled])).map(\.trip.trainId), ["433", "339"])
    }

    func testComparesExpectedTimesSoADelayCanMakeAConnectionWorthTaking() {
        // On time, the 6:38 beats the 6:14; running 30 minutes late, it doesn't.
        let early = home("59", leaves: 14, arrives: 83, via: ["Secaucus"])
        let onTime = home("657", leaves: 38, arrives: 83, via: ["Newark Broad"])
        XCTAssertEqual(Status.hidingDominatedConnections(homeViews([early, onTime])).map(\.trip.trainId), ["657"])
        var late = onTime
        late.status = .delayed
        late.statusNote = "Delayed 30 min"
        XCTAssertEqual(Status.hidingDominatedConnections(homeViews([early, late])).map(\.trip.trainId), ["59", "657"])
    }

    // MARK: tripKey

    func testBuildsAStableDirectionScopedKeyAndFailsSafelyWithoutATrainId() {
        XCTAssertEqual(Status.tripKey(trip()), "watchung|hoboken|1074")
        XCTAssertNil(Status.tripKey(trip(trainId: nil)))
    }
}
