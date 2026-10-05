import XCTest
@testable import GlassRailKit

/// The board derivations that lived inline in v4's app/board.tsx (untested
/// there), ported into BoardEngine so the app and widget share them.
final class BoardEngineTests: XCTestCase {
    /// 9:00 AM EDT, Friday 2026-07-31.
    let morning = date("2026-07-31T13:00:00.000Z")
    /// 5:00 PM EDT the same day.
    let evening = date("2026-07-31T21:00:00.000Z")

    func at(_ base: Date, _ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    func payload(_ trips: [Trip], kind: SourceKind = .live, generatedAt: Date? = nil) -> Payload {
        Payload(generatedAt: generatedAt ?? morning, source: PayloadSource(kind: kind, detail: "test"), trips: trips)
    }

    func trip(_ train: String, _ from: String, _ to: String, _ dep: Date, duration: Double = 39, track: String? = nil,
              transfers: [String] = [], legs: [String]? = nil, status: TripStatus? = nil, statusNote: String? = nil) -> Trip {
        makeTrip(fromId: from, toId: to, trainId: train, departure: dep, arrival: dep.addingTimeInterval(duration * 60), track: track,
                 transferCount: transfers.count, transferAt: transfers, legTrainIds: legs, status: status, statusNote: statusNote)
    }

    var weekday: [Trip] {
        [
            trip("1074", "watchung", "hoboken", at(morning, 10), track: "2"),
            trip("1078", "watchung", "hoboken", at(morning, 32)),
            trip("1082", "watchung", "hoboken", at(morning, 62)),
            trip("6222", "watchung", "penn", at(morning, 18), duration: 52, transfers: ["Secaucus"], legs: ["6222", "3852"]),
            trip("1207", "hoboken", "watchung", at(morning, 21)),
            trip("1291", "hoboken", "watchung", at(evening, 12)),
            trip("3855", "penn", "watchung", at(evening, 5), duration: 55),
        ]
    }

    func compute(_ payload: Payload, now: Date? = nil, destination: String = "hoboken", override: ModeOverride? = nil,
                 pin: Pin? = nil, ride: RideCache? = nil, runs: Runs = [:], failures: Int = 0) -> BoardState {
        BoardEngine.compute(BoardInputs(payload: payload, runs: runs, now: now ?? morning, destinationId: destination,
                                        modeOverride: override, pin: pin, rideCache: ride, fetchFailures: failures))
    }

    // MARK: Direction and destination

    func testMorningShowsTheRideIntoTheCity() {
        let state = compute(payload(weekday))
        XCTAssertEqual(state.commuteMode, .am)
        XCTAssertEqual(state.from.id, "watchung")
        XCTAssertEqual(state.to.id, "hoboken")
        XCTAssertEqual(state.dirKey, "watchung|hoboken")
        XCTAssertEqual(state.hero?.trip.trainId, "1074")
        XCTAssertEqual(state.later.map(\.trip.trainId), ["1078", "1082"])
        XCTAssertFalse(state.isPinned)
        XCTAssertFalse(state.riding)
        XCTAssertEqual(state.feedMode, .live)
    }

    func testEveningShowsTheRideHomeAndPennWhenChosen() {
        let state = compute(payload(weekday, generatedAt: evening), now: evening, destination: "penn")
        XCTAssertEqual(state.commuteMode, .pm)
        XCTAssertEqual(state.dirKey, "penn|watchung")
        XCTAssertEqual(state.hero?.trip.trainId, "3855")
    }

    func testAManualFlipShowsTheOtherDirection() {
        let state = compute(payload(weekday), override: ModeOverride(mode: .pm, at: morning))
        XCTAssertEqual(state.dirKey, "hoboken|watchung")
        XCTAssertEqual(state.hero?.trip.trainId, "1207")
    }

    func testAnUnknownDestinationFallsBackToHoboken() {
        XCTAssertEqual(compute(payload(weekday), destination: "nowhere").to.id, "hoboken")
    }

    // MARK: True times

    func testLiveStopTimesReorderTheBoardAndDriveTheHero() {
        // 1074 is 25 minutes late at Watchung; 1078 is on time and now leaves first.
        let runs: Runs = [
            "1074": [
                TrainStop(name: "Upper Montclair", time: at(morning, 33), departed: false, status: "Late", note: nil),
                TrainStop(name: "Watchung Avenue", time: at(morning, 35), departed: false, status: "Late", note: nil),
                TrainStop(name: "Hoboken", time: at(morning, 70), departed: false, status: "Late", note: nil),
            ],
        ]
        let state = compute(payload(weekday), runs: runs)
        XCTAssertEqual(state.hero?.trip.trainId, "1078")
        XCTAssertEqual(state.later.first?.trip.trainId, "1074")
        XCTAssertEqual(state.later.first?.expectedDeparture, at(morning, 35))
        XCTAssertEqual(state.later.first?.delayMinutes, 25)
        XCTAssertEqual(state.later.first?.timing?.dropoff?.delayMinutes, 21)
        XCTAssertEqual(state.hero?.timing?.pickup.live, false) // no stop list for 1078: "Scheduled"
    }

    func testSampleDataIgnoresStopListTiming() {
        // The same late stop list that reorders a live board must not make sample data look late.
        let runs: Runs = [
            "1074": [
                TrainStop(name: "Upper Montclair", time: at(morning, 33), departed: false, status: "Late", note: nil),
                TrainStop(name: "Watchung Avenue", time: at(morning, 35), departed: false, status: "Late", note: nil),
                TrainStop(name: "Hoboken", time: at(morning, 70), departed: false, status: "Late", note: nil),
            ],
        ]
        let state = compute(payload(weekday, kind: .sample), runs: runs)
        XCTAssertEqual(state.feedMode, .sample)
        XCTAssertEqual(state.hero?.trip.trainId, "1074")
        XCTAssertEqual(state.hero?.delayMinutes ?? 0, 0)
        XCTAssertEqual(state.hero?.timing?.pickup.live, false)
        XCTAssertEqual(state.hero?.timing?.pickup.delayMinutes ?? 0, 0)
        XCTAssertEqual(state.hero?.expectedDeparture, state.hero?.trip.departure)
    }

    func testSampleDataNeverCarriesAlertsOrANoServiceClaim() {
        var trips = weekday
        trips[0].status = .delayed
        trips[0].statusNote = "Delayed 10 min"
        let sample = compute(payload(trips, kind: .sample))
        XCTAssertEqual(sample.feedMode, .sample)
        XCTAssertFalse(sample.alerts)
        XCTAssertEqual(sample.hero?.delayed, false)
        XCTAssertFalse(compute(payload([], kind: .sample)).noService)
    }

    func testTheOnTimeChipNeedsLiveData() {
        let sample = SampleFixture.payload(now: morning)
        let sampleState = compute(sample)
        guard let sampleHero = sampleState.hero else { return XCTFail("expected a hero") }
        XCTAssertEqual(sampleHero.trip.trainId, "1067")
        XCTAssertEqual(sampleHero.trip.status, .onTime, "the fixture itself says on time")
        XCTAssertFalse(sampleState.showsOnTime(sampleHero), "SAMPLE never claims a train is on time")

        var live = sample
        live.source.kind = .live
        let liveState = compute(live)
        guard let liveHero = liveState.hero else { return XCTFail("expected a hero") }
        XCTAssertTrue(liveState.showsOnTime(liveHero))
    }

    func testStaleAfterTwoFailedRefreshes() {
        XCTAssertEqual(compute(payload(weekday), failures: 1).feedMode, .live)
        XCTAssertEqual(compute(payload(weekday), failures: 2).feedMode, .stale)
    }

    // MARK: Pins and rides

    func testAPinnedLaterTrainTakesOverTheHero() {
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1078")
        let state = compute(payload(weekday), pin: pin)
        XCTAssertEqual(state.hero?.trip.trainId, "1078")
        XCTAssertTrue(state.isPinned)
        XCTAssertFalse(state.riding)
        XCTAssertEqual(state.later.map(\.trip.trainId), ["1074", "1082"])
        XCTAssertEqual(state.trackedTrainIds.first, "1078")
    }

    func testAPinnedTrainIsFollowedAfterItLeavesTheFeed() {
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1074")
        let riding = trip("1074", "watchung", "hoboken", at(morning, -12), track: "2")
        let feed = payload(Array(weekday.dropFirst())) // the planner no longer offers 1074
        let state = compute(feed, pin: pin, ride: RideCache(key: pin.key, trip: riding))
        XCTAssertEqual(state.hero?.trip.trainId, "1074")
        XCTAssertTrue(state.riding)
        XCTAssertTrue(state.isPinned)
        XCTAssertEqual(state.later.map(\.trip.trainId), ["1078", "1082"])
        XCTAssertEqual(state.retainedTrip, riding)
        XCTAssertEqual(state.progress, 12.0 / 39.0, accuracy: 1e-9) // schedule fallback without a stop list
    }

    func testARideIsReleasedShortlyAfterArrival() {
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1074")
        let arrived = trip("1074", "watchung", "hoboken", at(morning, -50), track: "2") // arrived 11 min ago
        let state = compute(payload(Array(weekday.dropFirst())), pin: pin, ride: RideCache(key: pin.key, trip: arrived))
        XCTAssertEqual(state.hero?.trip.trainId, "1078")
        XCTAssertFalse(state.riding)
        XCTAssertFalse(state.isPinned)
    }

    func testAPinForTheOtherDirectionDoesNotApplyAndItsRideCacheIsDropped() {
        let pin = Pin(dirKey: "hoboken|watchung", key: "hoboken|watchung|1207")
        let state = compute(payload(weekday), pin: pin, ride: RideCache(key: pin.key, trip: weekday[4]))
        XCTAssertNil(state.activePinKey)
        XCTAssertEqual(state.hero?.trip.trainId, "1074")
        XCTAssertNil(BoardEngine.updatedRideCache(RideCache(key: pin.key, trip: weekday[4]), state: state))
    }

    func testTheRideCacheFollowsTheFreshestCopyOfThePinnedTrip() {
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1078")
        let state = compute(payload(weekday), pin: pin)
        XCTAssertEqual(BoardEngine.updatedRideCache(nil, state: state), RideCache(key: pin.key, trip: weekday[1]))
    }

    // MARK: The next day

    func testAPinLapsesThreeHoursAfterItsTrainLeft() {
        let pinned = trip("1074", "watchung", "hoboken", at(morning, 10))
        XCTAssertFalse(BoardEngine.pinExpired(trip: pinned, pinnedAt: morning, now: at(morning, 10 + 179)))
        XCTAssertTrue(BoardEngine.pinExpired(trip: pinned, pinnedAt: morning, now: at(morning, 10 + 181)))
        // Pinned well before its train: the clock starts when the train leaves.
        XCTAssertFalse(BoardEngine.pinExpired(trip: pinned, pinnedAt: at(morning, -170), now: at(morning, 60)))
        // Without the trip, from when it was pinned.
        XCTAssertTrue(BoardEngine.pinExpired(trip: nil, pinnedAt: morning, now: at(morning, 181)))
        XCTAssertFalse(BoardEngine.pinExpired(trip: nil, pinnedAt: nil, now: at(morning, 24 * 60)))
    }

    func testARideThatIsOverSaysSoSoThePinCanGo() {
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1074")
        let feed = payload(Array(weekday.dropFirst())) // the planner no longer offers 1074
        let riding = trip("1074", "watchung", "hoboken", at(morning, -12), track: "2")
        XCTAssertFalse(compute(feed, pin: pin, ride: RideCache(key: pin.key, trip: riding)).pinRideOver)
        let arrived = trip("1074", "watchung", "hoboken", at(morning, -50), track: "2") // arrived 11 min ago
        XCTAssertTrue(compute(feed, pin: pin, ride: RideCache(key: pin.key, trip: arrived)).pinRideOver)
        let upcoming = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1078")
        XCTAssertFalse(compute(payload(weekday), pin: upcoming).pinRideOver)
        XCTAssertFalse(compute(payload(weekday)).pinRideOver)
    }

    func testThePinnedRideIsKeptWhileTheOtherDirectionIsOnScreen() {
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1074")
        let ride = RideCache(key: pin.key, trip: trip("1074", "watchung", "hoboken", at(morning, -12)))
        let otherWay = compute(payload(weekday), override: ModeOverride(mode: .pm, at: morning), pin: pin, ride: ride)
        XCTAssertNil(otherWay.activePinKey)
        XCTAssertEqual(BoardEngine.updatedRideCache(ride, state: otherWay, pin: pin), ride)
        XCTAssertNil(BoardEngine.updatedRideCache(ride, state: otherWay, pin: nil), "no pin, no ride")
    }

    func testTomorrowsTrainOfTheSameNumberIsNotATrackChange() {
        var sameDay = TrackState()
        sameDay.ingest(payload([trip("1207", "hoboken", "watchung", at(evening, 10), track: "8")]), now: evening)
        sameDay.ingest(payload([trip("1207", "hoboken", "watchung", at(evening, 10), track: "6")]), now: at(evening, 2))
        XCTAssertEqual(sameDay.changes["hoboken|watchung|1207"]?.to, "6", "within the day a new track is a change")

        let tomorrow = at(evening, 24 * 60)
        var nextDay = TrackState()
        nextDay.ingest(payload([trip("1207", "hoboken", "watchung", at(evening, 10), track: "8")]), now: evening)
        nextDay.ingest(payload([trip("1207", "hoboken", "watchung", at(tomorrow, 10), track: "6")]), now: tomorrow)
        XCTAssertTrue(nextDay.changes.isEmpty, "tomorrow's 1207 from another track is not a change")
        XCTAssertEqual(nextDay.history["hoboken|watchung|1207"], "6")
    }

    func testYesterdaysStopListDoesNotDescribeTodaysTrain() {
        let today = trip("1074", "watchung", "hoboken", at(morning, 10), track: "2")
        func run(_ day: Date) -> [TrainStop] {
            [
                TrainStop(name: "Watchung Avenue", time: at(day, 10), departed: day < morning, status: nil, note: nil),
                TrainStop(name: "Hoboken", time: at(day, 49), departed: day < morning, status: nil, note: nil),
            ]
        }
        let stale = compute(payload([today]), runs: ["1074": run(at(morning, -24 * 60))])
        XCTAssertEqual(stale.hero?.trip.trainId, "1074")
        XCTAssertNil(stale.heroStops, "yesterday's run of 1074 is not today's")
        XCTAssertEqual(stale.progress, 0, accuracy: 1e-9, "not shown as arrived")
        let fresh = compute(payload([today]), runs: ["1074": run(morning)])
        XCTAssertEqual(fresh.heroStops?.count, 2)
    }

    func testAConnectionOntoATrainThatNoLongerCallsThereIsCancelledWithTheReason() {
        // Penn Station to Watchung Avenue by NEC 3833 to Secaucus, then 6233:
        // but today 6233 runs from Hoboken by Newark Broad Street.
        let connection = trip("3833", "penn", "watchung", at(evening, 10), duration: 60, transfers: ["Secaucus"], legs: ["3833", "6233"])
        let feed = payload([connection], generatedAt: evening)
        func stop(_ name: String, _ minutes: Double) -> TrainStop {
            TrainStop(name: name, time: at(evening, minutes), departed: false, status: nil, note: nil)
        }
        let viaNewarkBroad = ["6233": [stop("Hoboken", 5), stop("Newark Broad Street", 25), stop("Watchung Avenue", 60)]]
        let broken = compute(feed, now: evening, destination: "penn", runs: viaNewarkBroad).hero
        XCTAssertEqual(broken?.trip.trainId, "3833")
        XCTAssertEqual(broken?.cancelled, true)
        XCTAssertEqual(broken?.trip.statusNote, "Train 6233 isn't stopping at Secaucus today")

        let viaSecaucus = ["6233": [stop("New York Penn Station", 29), stop("Secaucus Upper Lvl", 38), stop("Watchung Avenue", 69)]]
        XCTAssertEqual(compute(feed, now: evening, destination: "penn", runs: viaSecaucus).hero?.cancelled, false)
        XCTAssertEqual(compute(feed, now: evening, destination: "penn").hero?.cancelled, false, "no stop list, no verdict")
        var skipped = viaSecaucus
        skipped["6233"]?[1].status = "Cancelled"
        XCTAssertEqual(compute(feed, now: evening, destination: "penn", runs: skipped).hero?.cancelled, true)
        // Yesterday's list for 6233 says nothing about today.
        let yesterday = viaNewarkBroad.mapValues { stops in
            stops.map { stop -> TrainStop in
                var old = stop
                old.time = stop.time?.addingTimeInterval(-24 * 3600)
                return old
            }
        }
        XCTAssertEqual(compute(feed, now: evening, destination: "penn", runs: yesterday).hero?.cancelled, false)
    }

    func testATrainItsBoardStillListsIsNotGoneBecauseItsStopListSaysSo() {
        // Hoboken's board still listed 6233 ("All Aboard") while its stop list
        // put Hoboken a minute earlier: it was boarding, not gone.
        var boarding = trip("6233", "hoboken", "watchung", at(evening, 0), duration: 41, track: "6")
        boarding.listedAt = evening
        boarding.countdownMinutes = 0
        let runs: Runs = ["6233": [
            TrainStop(name: "Hoboken", time: at(evening, -1), departed: false, status: nil, note: nil),
            TrainStop(name: "Watchung Avenue", time: at(evening, 40), departed: false, status: nil, note: nil),
        ]]
        let feed = payload([boarding], generatedAt: evening)
        let state = compute(feed, now: at(evening, 0.5), destination: "hoboken", runs: runs)
        XCTAssertEqual(state.hero?.trip.trainId, "6233")
        XCTAssertEqual(state.hero?.expectedDeparture, at(evening, -1), "the live time, a minute early")
        XCTAssertEqual(state.hero?.holdUntil, evening)
        // Once its stop list says it has left Hoboken, it's gone.
        var left = runs
        left["6233"]?[0].departed = true
        XCTAssertNil(compute(feed, now: at(evening, 0.5), destination: "hoboken", runs: left).hero)
    }

    func testATrainThatLeavesFromTheOtherTerminalTodayIsCancelledFromThisOne() {
        // 6237 leaves Penn Station in the timetable; today Hoboken's board has
        // it, and Penn Station's board says nothing about it.
        let fromPenn = trip("6237", "penn", "watchung", at(evening, 29), duration: 40)
        let pair = ODPair(fromId: "penn", toId: "watchung")
        let boards: [String: [String: BoardEntry]] = [
            "watchung": ["6237": BoardEntry(track: "1", note: nil, departureRaw: "6:09 PM", status: nil, destination: "MSU")],
            "hoboken": ["6237": BoardEntry(track: "6", note: nil, departureRaw: "5:28 PM", status: nil, destination: "MSU -SEC")],
            "penn": ["3837": BoardEntry(track: "9", note: nil, departureRaw: "5:09 PM", status: nil, destination: "Trenton")],
        ]
        let moved = BoardTruth.reconcile([fromPenn], pair: pair, boards: boards, fetchedAt: evening).first { $0.trainId == "6237" }
        XCTAssertEqual(moved?.status, .cancelled)
        XCTAssertEqual(moved?.statusNote, "Leaves from Hoboken today")
        // From Hoboken it is the ride home.
        let fromHoboken = BoardTruth.reconcile([], pair: ODPair(fromId: "hoboken", toId: "watchung"), boards: boards, fetchedAt: evening)
        XCTAssertEqual(fromHoboken.map(\.trainId), ["6237"])
        XCTAssertNil(fromHoboken.first?.status)
        // A train Penn Station's own board lists is left alone.
        var listed = boards
        listed["penn"]?["6237"] = BoardEntry(track: "7", note: nil, departureRaw: "5:29 PM", status: nil, destination: "MSU")
        XCTAssertNil(BoardTruth.reconcile([fromPenn], pair: pair, boards: listed, fetchedAt: evening).first?.status)
    }

    func testTheFeaturedTrainCanBeFollowed() {
        // The follow button pins the hero itself.
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1074")
        let state = compute(payload(weekday), pin: pin)
        XCTAssertEqual(state.hero?.trip.trainId, "1074")
        XCTAssertTrue(state.isPinned)
        XCTAssertEqual(state.later.map(\.trip.trainId), ["1078", "1082"])
    }

    func testLaterListsEveryTrainThisWay() {
        let many = (0..<15).map { (index: Int) -> Trip in
            let minutes = Double(5 + 10 * index)
            return trip(String(2000 + index), "watchung", "hoboken", at(morning, minutes))
        }
        let state = compute(payload(many))
        XCTAssertEqual(state.hero?.trip.trainId, "2000")
        XCTAssertEqual(state.later.count, 14)
    }

    func testTracksThePinnedTrainAndConnectionsFirstCappedAtSix() {
        let pin = Pin(dirKey: "watchung|penn", key: "watchung|penn|6222")
        let base = Status.selectTripViews(weekday, fromId: "watchung", toId: "hoboken", now: morning, alerts: true, changes: [:])
        let ids = BoardEngine.trackedTrainIds(base: base, pin: pin, rideCache: RideCache(key: pin.key, trip: weekday[3]))
        XCTAssertEqual(ids, ["6222", "3852", "1074", "1078", "1082"])
        let many = (0..<10).map { trip(String(2000 + $0), "watchung", "hoboken", at(morning, Double(5 + $0))) }
        let manyViews = Status.selectTripViews(many, fromId: "watchung", toId: "hoboken", now: morning, alerts: true, changes: [:])
        XCTAssertEqual(BoardEngine.trackedTrainIds(base: manyViews, pin: nil, rideCache: nil).count, BoardEngine.stopListTrains)
    }

    // MARK: Travel alerts

    func testShowsNJTransitsTravelAlertsOnlyWithLiveData() {
        var live = payload(weekday)
        live.alerts = ["Midtown Direct trains are being diverted to Hoboken."]
        XCTAssertEqual(compute(live).serviceAlerts, ["Midtown Direct trains are being diverted to Hoboken."])
        var sample = payload(weekday, kind: .sample)
        sample.alerts = ["Midtown Direct trains are being diverted to Hoboken."]
        XCTAssertEqual(compute(sample).serviceAlerts, [])
    }

    // MARK: One way per train

    func testListsTheBestWayToCatchEachTrainHomeAndKeepsAPinnedOne() {
        let ways = [
            trip("59", "hoboken", "watchung", at(evening, 14), duration: 69, transfers: ["Secaucus"], legs: ["59", "6283"]),
            trip("657", "hoboken", "watchung", at(evening, 38), duration: 45, transfers: ["Newark Broad"], legs: ["657", "6283"]),
            trip("1011", "hoboken", "watchung", at(evening, 33), duration: 36),
        ]
        let state = compute(payload(ways, generatedAt: evening), now: evening)
        XCTAssertEqual(state.direction.map(\.trip.trainId), ["1011", "657"])
        XCTAssertEqual(state.hero?.trip.trainId, "1011")
        XCTAssertFalse(state.trackedTrainIds.contains("59"), "no stop list for a row that isn't shown")

        let pin = Pin(dirKey: "hoboken|watchung", key: "hoboken|watchung|59")
        let pinned = compute(payload(ways, generatedAt: evening), now: evening, pin: pin)
        XCTAssertEqual(pinned.hero?.trip.trainId, "59")
        XCTAssertTrue(pinned.isPinned)
        XCTAssertFalse(pinned.riding)
    }

    // MARK: No service

    func testNamesTheNearestStationWithServiceWhenHomeHasNone() {
        let weekend = [
            trip("1911", "baystreet", "hoboken", at(morning, 14)),
            trip("1915", "baystreet", "hoboken", at(morning, 74)),
        ]
        let state = compute(payload(weekend))
        XCTAssertTrue(state.noService)
        XCTAssertNil(state.hero)
        XCTAssertEqual(state.alternate?.from.id, "baystreet")
        XCTAssertEqual(state.alternate?.to.id, "hoboken")
        XCTAssertEqual(state.alternate?.views.map(\.trip.trainId), ["1911", "1915"])
    }

    func testNoServiceWithoutAnAlternate() {
        let state = compute(payload([]))
        XCTAssertTrue(state.noService)
        XCTAssertNil(state.alternate)
    }

    // MARK: Journey dot

    func testTheDotFollowsLiveStopFlags() {
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1074")
        let riding = trip("1074", "watchung", "hoboken", at(morning, -12), track: "2")
        let runs: Runs = ["1074": Demo.stops(now: morning, departure: riding.departure, arrival: riding.arrival, originName: "Watchung Avenue", destName: "Hoboken")]
        let state = compute(payload([riding] + weekday.dropFirst()), pin: pin, runs: runs)
        XCTAssertEqual(state.heroStops?.count, 11)
        XCTAssertGreaterThan(state.progress, 0.2)
        XCTAssertLessThan(state.progress, 0.45)
    }

    // MARK: Departure notice and track history

    func testAnnouncesTheHeroOnceAfterItLeaves() {
        var watcher = DepartureWatcher()
        let feed = payload(weekday)
        XCTAssertNil(watcher.observe(compute(feed), now: morning))
        // 1074 leaves at +10 and drops off the board a minute later.
        let later = at(morning, 11.5)
        XCTAssertEqual(watcher.observe(compute(payload(weekday, generatedAt: later), now: later), now: later), "1074")
        XCTAssertNil(watcher.observe(compute(payload(weekday, generatedAt: later), now: later), now: later))
    }

    func testStaysQuietWhilePinnedOrStaleOrAfterAFlip() {
        var watcher = DepartureWatcher()
        _ = watcher.observe(compute(payload(weekday)), now: morning)
        let later = at(morning, 11.5)
        // Stale feed: no announcement.
        XCTAssertNil(watcher.observe(compute(payload(weekday), now: later), now: later))

        var flipped = DepartureWatcher()
        _ = flipped.observe(compute(payload(weekday)), now: morning)
        let otherWay = compute(payload(weekday, generatedAt: later), now: later, override: ModeOverride(mode: .pm, at: later))
        XCTAssertNil(flipped.observe(otherWay, now: later))

        var pinned = DepartureWatcher()
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1078")
        _ = pinned.observe(compute(payload(weekday)), now: morning)
        XCTAssertNil(pinned.observe(compute(payload(weekday, generatedAt: later), now: later, pin: pin), now: later))
    }

    func testTrackStateReportsAChangeOnlyForLivePayloadsAndItExpires() {
        var first = weekday
        first[1].track = "1"
        var moved = first
        moved[1].track = "4"

        var state = TrackState()
        state.ingest(payload(first), now: morning)
        XCTAssertTrue(state.changes.isEmpty)
        state.ingest(payload(moved, kind: .sample), now: morning)
        XCTAssertTrue(state.changes.isEmpty)
        state.ingest(payload(moved), now: at(morning, 1))
        XCTAssertEqual(state.changes["watchung|hoboken|1078"], TrackChange(from: "1", to: "4", detectedAt: at(morning, 1)))

        func board(at minutes: Double) -> BoardState {
            BoardEngine.compute(BoardInputs(payload: payload(moved, generatedAt: at(morning, minutes)), now: at(morning, minutes),
                                            destinationId: "hoboken", trackChanges: state.changes))
        }
        XCTAssertEqual(board(at: 2).direction.first { $0.trip.trainId == "1078" }?.trackChange?.to, "4")
        XCTAssertNil(board(at: 2).hero?.trackChange)
        // Ten minutes on, the new track is the quiet normal.
        XCTAssertNil(board(at: 12).direction.first { $0.trip.trainId == "1078" }?.trackChange)
    }

    // MARK: The v4 QA scenarios end to end

    func testRidingScenarioKeepsTheTrainAfterTheFeedDropsIt() {
        let now = morning
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1074")
        let first = Demo.payload(.riding, step: 0, now: now)
        let firstState = compute(first, now: now, override: ModeOverride(mode: .am, at: now), pin: pin, runs: Demo.runs(for: first, now: now))
        XCTAssertTrue(firstState.riding)
        let cache = BoardEngine.updatedRideCache(nil, state: firstState)
        XCTAssertNotNil(cache)

        let second = Demo.payload(.riding, step: 1, now: now)
        let secondState = compute(second, now: now, override: ModeOverride(mode: .am, at: now), pin: pin, ride: cache, runs: Demo.runs(for: first, now: now))
        XCTAssertEqual(secondState.hero?.trip.trainId, "1074")
        XCTAssertTrue(secondState.riding)
    }

    func testDelayedScenarioShowsSixMinutesOutAndTwoIn() {
        let now = morning
        let p = Demo.payload(.delayed, step: 0, now: now)
        let state = compute(p, now: now, runs: Demo.runs(for: p, now: now))
        XCTAssertEqual(state.hero?.trip.trainId, "1074")
        XCTAssertEqual(state.hero?.delayMinutes, 6)
        XCTAssertEqual(state.hero?.timing?.pickup.live, true)
        XCTAssertEqual(state.hero?.timing?.dropoff?.delayMinutes, 2)
        XCTAssertEqual(state.hero?.expectedDeparture, at(now, 46))
    }
}
