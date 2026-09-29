import XCTest
@testable import GlassRailKit

/// Port of tests/demo.test.ts (15 cases).
final class DemoTests: XCTestCase {
    let now = date("2026-07-31T13:00:00.000Z")

    func minutes(_ interval: TimeInterval) -> Double { interval / 60 }

    // MARK: parseDemoScenario

    func testAcceptsKnownScenariosAndRejectsEverythingElse() {
        XCTAssertEqual(DemoScenario.parse("delayed"), .delayed)
        XCTAssertEqual(DemoScenario.parse("track"), .track)
        XCTAssertEqual(DemoScenario.parse("departed"), .departed)
        XCTAssertEqual(DemoScenario.parse("stale"), .stale)
        XCTAssertEqual(DemoScenario.parse("sample"), .sample)
        XCTAssertEqual(DemoScenario.parse("riding"), .riding)
        XCTAssertNil(DemoScenario.parse("nonsense"))
        XCTAssertNil(DemoScenario.parse(nil))
    }

    // MARK: demoPayload

    func testDelayedScenarioIsLiveMarkedWithADelayedHeroCarryingMinutes() {
        let p = Demo.payload(.delayed, step: 0, now: now)
        XCTAssertEqual(p.source.kind, .live)
        let hero = p.trips.first { $0.fromId == "watchung" && $0.status == .delayed }
        XCTAssertNotNil(hero)
        XCTAssertTrue(RX.test("\\d+ min", hero?.statusNote ?? "", ignoreCase: true))
    }

    func testTrackScenarioMovesTheSameTrainBetweenSteps() {
        let first = Demo.payload(.track, step: 0, now: now).trips[0]
        let second = Demo.payload(.track, step: 1, now: now).trips[0]
        XCTAssertEqual(first.trainId, second.trainId)
        XCTAssertNotEqual(first.track, second.track)
    }

    func testDepartedScenariosStep1HeroHasAlreadyLeft() {
        let second = Demo.payload(.departed, step: 1, now: now)
        let gone = second.trips.allSatisfy { $0.fromId != "watchung" || $0.trainId != "1074" || $0.departure < now }
        XCTAssertTrue(gone)
    }

    func testStaleScenarioBackdatesGeneratedAtBeyondTheStaleThreshold() {
        let p = Demo.payload(.stale, step: 0, now: now)
        XCTAssertEqual(p.source.kind, .live)
        XCTAssertGreaterThan(now.timeIntervalSince(p.generatedAt), 210)
    }

    func testSampleScenarioIsSampleMarkedEvenThoughTripsCarryStatuses() {
        let p = Demo.payload(.sample, step: 0, now: now)
        XCTAssertEqual(p.source.kind, .sample)
        XCTAssertTrue(p.trips.contains { $0.status == .delayed })
    }

    func testRidingScenarioDropsThePinnedTrainFromTheFeedOnRefresh() {
        XCTAssertTrue(Demo.payload(.riding, step: 0, now: now).trips.contains { $0.trainId == "1074" })
        XCTAssertFalse(Demo.payload(.riding, step: 1, now: now).trips.contains { $0.trainId == "1074" })
    }

    func testRidingScenariosHeroHasDepartedButNotYetArrived() {
        let hero = Demo.payload(.riding, step: 0, now: now).trips[0]
        XCTAssertEqual(hero.trainId, "1074")
        XCTAssertLessThan(hero.departure, now)
        XCTAssertGreaterThan(hero.arrival ?? .distantPast, now)
    }

    // MARK: demoRuns

    func testBuildsARunPerTrainKeyedByTrainId() {
        let runs = Demo.runs(for: Demo.payload(.delayed, step: 0, now: now), now: now)
        XCTAssertNotNil(runs["1074"])
        XCTAssertGreaterThan(runs["1074"]?.count ?? 0, 3)
    }

    func testShiftsADelayedTrainsStopTimesSoTheLiveDelayIsReproducible() {
        let payload = Demo.payload(.delayed, step: 0, now: now)
        let hero = payload.trips.first { $0.trainId == "1074" }!
        let origin = Demo.runs(for: payload, now: now)["1074"]!.first { $0.name == "Watchung Avenue" }!
        XCTAssertEqual(minutes(origin.time!.timeIntervalSince(hero.departure)), 6)
    }

    func testRecoversSomeDelayByTheDestinationSoTheLegsDiffer() {
        let payload = Demo.payload(.delayed, step: 0, now: now)
        let hero = payload.trips.first { $0.trainId == "1074" }!
        let dest = Demo.runs(for: payload, now: now)["1074"]!.last!
        XCTAssertEqual(minutes(dest.time!.timeIntervalSince(hero.arrival!)), 2)
    }

    func testLeavesAnOnTimeTrainsStopsOnSchedule() {
        let payload = Demo.payload(.track, step: 0, now: now)
        let hero = payload.trips.first { $0.trainId == "1074" }!
        let origin = Demo.runs(for: payload, now: now)["1074"]!.first { $0.name == "Watchung Avenue" }!
        XCTAssertEqual(origin.time, hero.departure)
    }

    // MARK: demoStops

    var dep: Date { now.addingTimeInterval(-12 * 60) }
    var arr: Date { now.addingTimeInterval(27 * 60) }

    func testBuildsARunWhereTheOriginHasDepartedAndTheDestinationHasNot() {
        let stops = Demo.stops(now: now, departure: dep, arrival: arr, originName: "Watchung Avenue", destName: "Hoboken")
        XCTAssertEqual(stops.first { $0.name == "Watchung Avenue" }?.departed, true)
        XCTAssertEqual(stops.first { $0.name == "Hoboken" }?.departed, false)
        XCTAssertTrue(stops.allSatisfy { $0.time != nil })
    }

    func testIncludesInboundStopsBeforeAMidLineOriginButNoneBeforeATerminal() {
        let fromWatchung = Demo.stops(now: now, departure: dep, arrival: arr, originName: "Watchung Avenue", destName: "Hoboken")
        XCTAssertNotEqual(fromWatchung[0].name, "Watchung Avenue")
        let fromHoboken = Demo.stops(now: now, departure: dep, arrival: arr, originName: "Hoboken", destName: "Watchung Avenue")
        XCTAssertEqual(fromHoboken[0].name, "Hoboken")
    }

    func testMarksStopsDepartedStrictlyByTime() {
        let future = now.addingTimeInterval(40 * 60)
        let futureArr = now.addingTimeInterval(79 * 60)
        let stops = Demo.stops(now: now, departure: future, arrival: futureArr, originName: "Watchung Avenue", destName: "Hoboken")
        XCTAssertEqual(stops.first { $0.name == "Watchung Avenue" }?.departed, false)
        // The inbound tail includes at least one departed stop so "Past X" is
        // demonstrable before boarding.
        XCTAssertTrue(stops.contains { $0.departed })
    }
}
