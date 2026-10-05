import Foundation
import XCTest
@testable import GlassRailKit

/// Real NJ Transit replies captured from a GitHub runner at 9:11 AM ET on
/// Monday 5 October 2026, while New York Penn Station was closed to Midtown
/// Direct trains: Watchung Avenue's board sent 6216, 6222 and 6226 to
/// Hoboken (6216, due at 9:05, read "in 7 Min"), Penn Station's board had
/// 6231 and 6233 cancelled ("This train is now departing from Hoboken"), and
/// the trip planner still followed the timetable.
final class DisruptionTests: XCTestCase {
    /// 9:11 AM EDT, when the replies were captured.
    let captured = date("2026-10-05T13:11:00.000Z")

    func et(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").map { Int($0)! }
        return date(String(format: "2026-10-05T%02d:%02d:00.000Z", parts[0] + 4, parts[1]))
    }

    /// Every train on Watchung Avenue's board bound for the city in the next
    /// 6 hours (6246 at 4:27 PM is further out; see `BoardTruth.window`).
    let cityBound: Set<String> = ["6216", "1074", "6222", "6226", "6230", "6234", "6238", "6242"]

    /// The captured reply for a request; the planner answers the same at any time.
    static func reply(_ operation: String, _ variables: JSON) -> NJTHTTPResponse {
        switch operation {
        case "board":
            switch variables["station"].jsString {
            case "Watchung Avenue": return FakeNJT.ok(fixture("disruption-board-watchung"))
            case "Hoboken Terminal": return FakeNJT.ok(fixture("disruption-board-hoboken"))
            case "New York Penn Station": return FakeNJT.ok(fixture("disruption-board-penn"))
            default: return FakeNJT.emptyBoard
            }
        case "planner":
            switch (variables["origin"].jsString, variables["destination"].jsString) {
            case ("Watchung Avenue Station", "New York Penn Station"): return FakeNJT.ok(fixture("disruption-planner-watchung-penn"))
            case ("Watchung Avenue Station", "Hoboken Terminal"): return FakeNJT.ok(fixture("disruption-planner-watchung-hoboken"))
            case ("Hoboken Terminal", "Watchung Avenue Station"): return FakeNJT.ok(fixture("disruption-planner-hoboken-watchung"))
            case ("New York Penn Station", "Watchung Avenue Station"): return FakeNJT.ok(fixture("disruption-planner-penn-watchung"))
            default: return FakeNJT.emptyPlanner
            }
        default:
            return FakeNJT.ok(fixture("disruption-stops-6216"))
        }
    }

    func client(_ fake: FakeNJT) -> NJTClient {
        let fixed = captured
        return NJTClient(transport: fake, clock: { fixed }, retryDelay: 0)
    }

    func capturedPayload() async throws -> Payload {
        try await client(FakeNJT { Self.reply($0, $1) }).fetchLivePayload()
    }

    func board(_ payload: Payload, destination: String, at moment: Date? = nil, home: Bool = false, runs: Runs = [:]) -> BoardState {
        let now = moment ?? captured
        return BoardEngine.compute(BoardInputs(
            payload: payload,
            runs: runs,
            now: now,
            destinationId: destination,
            modeOverride: home ? ModeOverride(mode: .pm, at: now) : nil
        ))
    }

    var run6216: Runs {
        let list = fixtureJSON("disruption-stops-6216")["data"]?["getTrainStopList"]?.arrayValue ?? []
        return ["6216": NJTParse.parseStops(list, baseNow: captured)]
    }

    // MARK: The late train

    func testTheLateTrainStaysOnTheBoardAtItsRealTime() async throws {
        let payload = try await capturedPayload()
        let state = board(payload, destination: "hoboken")
        // Due at 9:05, "in 7 Min" at 9:11: it leaves at 9:18, 13 minutes late.
        XCTAssertEqual(state.hero?.trip.trainId, "6216")
        XCTAssertEqual(state.hero?.expectedDeparture, et("9:18"))
        XCTAssertEqual(state.hero?.delayed, true)
        XCTAssertEqual(state.hero?.delayMinutes, 13)
        XCTAssertEqual(state.hero?.trip.track, "2")
        // Still there three minutes later, while it is still on its way.
        XCTAssertEqual(board(payload, destination: "hoboken", at: et("9:14")).hero?.trip.trainId, "6216")
    }

    func testTheLiveStopListGivesThePickupAndTheDropOff() async throws {
        let state = board(try await capturedPayload(), destination: "hoboken", runs: run6216)
        XCTAssertEqual(state.hero?.trip.trainId, "6216")
        XCTAssertEqual(state.hero?.timing?.pickup.expected, et("9:18"))
        XCTAssertEqual(state.hero?.timing?.pickup.live, true)
        XCTAssertEqual(state.hero?.timing?.dropoff?.expected, et("9:43"))
        XCTAssertEqual(state.hero?.timing?.dropoff?.live, true)
    }

    func testALiveStopTimeKeepsALateTrainWhenTheBoardSaysNothing() {
        // No board data at all: only the stop list knows it's late.
        let trip = makeTrip(fromId: "watchung", toId: "hoboken", trainId: "6216", departure: et("9:05"), arrival: et("9:43"), track: nil)
        let payload = Payload(generatedAt: captured, source: PayloadSource(kind: .live, detail: "test"), trips: [trip])
        let state = board(payload, destination: "hoboken", at: et("9:10"), runs: run6216)
        XCTAssertEqual(state.hero?.trip.trainId, "6216")
        XCTAssertEqual(state.hero?.expectedDeparture, et("9:18"))
    }

    func testATrainStillListedAfterItsTimeIsLateNotGone() {
        var trip = makeTrip(fromId: "watchung", toId: "hoboken", trainId: "6216", departure: et("9:05"), arrival: et("9:43"))
        trip.listedAt = et("9:10")
        let view = Status.deriveTripView(trip, changes: [:], alerts: true)
        XCTAssertEqual(view.expectedDeparture, et("9:11"))
        XCTAssertTrue(view.delayed)
        XCTAssertNil(view.delayMinutes, "late by an unknown amount")
        // Sample data never shows a train as late.
        XCTAssertFalse(Status.deriveTripView(trip, changes: [:], alerts: false).delayed)
    }

    func testReadsTheBoardsCountdown() {
        XCTAssertEqual(NJTParse.parseCountdown("in 7 Min"), 7)
        XCTAssertEqual(NJTParse.parseCountdown("in 23 Min"), 23)
        XCTAssertEqual(NJTParse.parseCountdown("All Aboard"), 0)
        XCTAssertEqual(NJTParse.parseCountdown("<b>BOARDING</b>"), 0)
        XCTAssertNil(NJTParse.parseCountdown("DELAYED"))
        XCTAssertNil(NJTParse.parseCountdown(""))
        XCTAssertNil(NJTParse.parseCountdown(nil))
    }

    // MARK: Trains sent somewhere else

    func testATrainSentToHobokenIsDirectToHobokenAndEndsAtHobokenForPenn() async throws {
        let payload = try await capturedPayload()
        let toHoboken = payload.trips.filter { $0.fromId == "watchung" && $0.toId == "hoboken" }
        // The planner routed 6222 to Hoboken by a change at Secaucus; it runs straight there.
        XCTAssertEqual(toHoboken.filter { $0.trainId == "6222" }.map(\.transferCount), [0])
        XCTAssertNil(toHoboken.first { $0.trainId == "6222" }?.terminus)

        let toPenn = payload.trips.filter { $0.fromId == "watchung" && $0.toId == "penn" }
        // The planner said 6222 went direct to Penn Station; it ends at Hoboken.
        XCTAssertEqual(toPenn.filter { $0.trainId == "6222" }.map(\.terminus), ["Hoboken"])
        XCTAssertNil(toPenn.first { $0.trainId == "6222" }?.arrival)
        // 1074 really does go to Hoboken, and the change at Newark Broad still works.
        XCTAssertEqual(toPenn.first { $0.trainId == "1074" }?.transferAt, ["Newark Broad"])

        let penn = board(payload, destination: "penn")
        XCTAssertEqual(penn.hero?.trip.trainId, "6216")
        XCTAssertEqual(penn.hero?.trip.terminus, "Hoboken")
        XCTAssertEqual(penn.hero.map { Format.tripType($0.trip) }, "Ends at Hoboken")
    }

    func testEveryTrainOnWatchungAvenuesBoardIsListedBothWays() async throws {
        let payload = try await capturedPayload()
        for destination in ["hoboken", "penn"] {
            let trains = Set(payload.trips.filter { $0.fromId == "watchung" && $0.toId == destination }.compactMap(\.trainId))
            XCTAssertTrue(cityBound.isSubset(of: trains), "\(destination): missing \(cityBound.subtracting(trains).sorted())")
        }
    }

    func testTheBoardsSayWhereATrainRuns() {
        XCTAssertEqual(NJTParse.servedTerminal("Hoboken"), "hoboken")
        XCTAssertEqual(NJTParse.servedTerminal("New York -SEC"), "penn")
        XCTAssertNil(NJTParse.servedTerminal("MSU"))
        let viaSecaucus = makeTrip(departure: et("10:13"), arrival: et("11:06"), transferCount: 1, transferAt: ["Secaucus"])
        let viaNewark = makeTrip(departure: et("9:51"), arrival: et("10:41"), transferCount: 1, transferAt: ["Newark Broad"])
        XCTAssertFalse(NJTParse.connectionFits(viaSecaucus, firstTrainRunsTo: "hoboken"), "Hoboken trains don't call at Secaucus")
        XCTAssertTrue(NJTParse.connectionFits(viaSecaucus, firstTrainRunsTo: "penn"))
        XCTAssertTrue(NJTParse.connectionFits(viaNewark, firstTrainRunsTo: "hoboken"))
        XCTAssertFalse(NJTParse.connectionFits(makeTrip(departure: et("10:13"), arrival: et("10:56")), firstTrainRunsTo: "hoboken"))
    }

    // MARK: The ride home

    func testTheRideHomeIncludesATrainNowStartingFromHoboken() async throws {
        let payload = try await capturedPayload()
        let state = board(payload, destination: "hoboken", home: true)
        // The planner only knew connections onto 6231 (one by a cancelled stop
        // at Secaucus); Hoboken's board has it leaving at 9:43 from track 6.
        XCTAssertEqual(state.hero?.trip.trainId, "6231")
        XCTAssertEqual(state.hero?.trip.transferCount, 0)
        XCTAssertEqual(state.hero?.trip.track, "6")
        XCTAssertEqual(state.hero?.trip.departure, et("9:43"))
        XCTAssertEqual(state.hero?.trip.arrival, et("10:25"))
        XCTAssertEqual(state.direction.map(\.trip.trainId), ["6231", "6233"])
    }

    func testFromPennTheCancellationSaysWhereTheTrainLeavesFrom() async throws {
        let state = board(try await capturedPayload(), destination: "penn", home: true)
        let view = state.direction.first { $0.trip.trainId == "6231" }
        XCTAssertEqual(view?.cancelled, true)
        XCTAssertTrue(view?.trip.statusNote?.contains("now departing from Hoboken") ?? false, view?.trip.statusNote ?? "no note")
    }

    // MARK: Outages

    func testWhenThePlannerIsDownTheBoardStillListsEveryTrainIntoTheCity() async throws {
        let fake = FakeNJT { operation, variables in
            operation == "planner" ? NJTHTTPResponse(status: 500, body: Data("{}".utf8)) : Self.reply(operation, variables)
        }
        let payload = try await client(fake).fetchLivePayload(required: ["watchung|hoboken"])
        XCTAssertEqual(payload.source.kind, .live)
        let toHoboken = Set(payload.trips.filter { $0.fromId == "watchung" && $0.toId == "hoboken" }.compactMap(\.trainId))
        XCTAssertTrue(cityBound.isSubset(of: toHoboken))
        XCTAssertEqual(Set(payload.unanswered ?? []), ["hoboken|watchung", "penn|watchung"], "the rides home need the planner")
        let state = board(payload, destination: "hoboken")
        XCTAssertEqual(state.hero?.trip.trainId, "6216")
        XCTAssertEqual(state.feedMode, .live, "Watchung Avenue's board answered for this direction")
    }

    func testWhenTheTimetableSaysNoTrainsTheBoardAddsNone() async throws {
        // A board's times carry no date; on a day the timetable runs nothing at
        // Watchung Avenue (a weekend), the board is not allowed to add trains.
        let fake = FakeNJT { operation, variables in
            operation == "planner" ? FakeNJT.ok(fixture("live-planner-no-trips")) : Self.reply(operation, variables)
        }
        let payload = try await client(fake).fetchLivePayload()
        XCTAssertTrue(payload.trips.filter { $0.fromId == "watchung" || $0.toId == "watchung" }.isEmpty)
        XCTAssertTrue(board(payload, destination: "hoboken").noService)
    }

    func testBoardTrainsFarAheadAreLeftToThePlanner() async throws {
        let payload = try await capturedPayload()
        // 6246 at 4:27 PM is more than 6 hours after the 9:11 reading.
        XCTAssertFalse(payload.trips.contains { $0.fromId == "watchung" && $0.trainId == "6246" })
    }

    func testRetriesAFailureThatIsLikelyToPassButNotATimeout() async throws {
        let attempts = Counter()
        let flaky = FakeNJT { operation, variables in
            attempts.increment() == 1 ? NJTHTTPResponse(status: 503, body: Data("<html>busy</html>".utf8)) : Self.reply(operation, variables)
        }
        let items = try await client(flaky).fetchDepartureBoard("Watchung Avenue")
        XCTAssertEqual(items.count, 19)
        XCTAssertEqual(attempts.value, 2)

        XCTAssertTrue(NJTClient.worthRetrying(NJTError.http(502)))
        XCTAssertTrue(NJTClient.worthRetrying(NJTError.http(429)))
        XCTAssertTrue(NJTClient.worthRetrying(NJTError.notJSON))
        XCTAssertTrue(NJTClient.worthRetrying(URLError(.networkConnectionLost)))
        XCTAssertFalse(NJTClient.worthRetrying(URLError(.timedOut)))
        XCTAssertFalse(NJTClient.worthRetrying(NJTError.http(404)))
        XCTAssertFalse(NJTClient.worthRetrying(NJTError.graphQL("Station not found")))
    }

    func testAFailedFirstLookupIsCoveredByTheTrainLookups() {
        var window = PlannerWindow(origin: "Watchung Avenue Station", destination: "Hoboken Terminal", lookups: 4)
        window.failedLookups = [0]
        XCTAssertTrue(window.failed)
        window.seedLookups = 3
        window.failedSeeds = 1
        XCTAssertFalse(window.failed, "two train lookups answered for the next trains")
        window.failedSeeds = 3
        XCTAssertTrue(window.failed)
    }

    // MARK: Stress

    /// NJ Transit failing at random (HTTP 500, 429, HTML error pages, GraphQL
    /// errors) on about one request in three, over 150 refreshes. Whatever
    /// fails, a refresh either fails as a whole (the app then keeps its last
    /// board, turning it STALE) or tells the truth: when Watchung Avenue's
    /// board loaded, every train on it bound for the city is listed, the late
    /// 6216 leads at its real time, there is never a "no trains" claim, and no
    /// trip says a train runs somewhere the board says it doesn't.
    func testStaysTruthfulWhenNJTransitFailsAtRandom() async throws {
        let boardItems = fixtureJSON("disruption-board-watchung")["data"]?["getTrainDepartureScreens"]?["items"]?.arrayValue ?? []
        let homeBoard = NJTParse.buildBoardIndex(boardItems)
        var refreshed = 0, failed = 0, boardLoaded = 0
        for seed in 1...150 {
            let chaos = Chaos(seed: UInt64(seed), rate: 0.33)
            let fake = FakeNJT { operation, variables in chaos.failure() ?? Self.reply(operation, variables) }
            do {
                let payload = try await client(fake).fetchLivePayload(required: ["watchung|hoboken"])
                refreshed += 1
                // Trips leaving Watchung carry `listedAt` only when its board loaded.
                let fromHome = payload.trips.filter { $0.fromId == "watchung" }
                guard fromHome.contains(where: { $0.listedAt != nil }) else { continue }
                boardLoaded += 1
                for trip in fromHome where trip.transferCount == 0 && trip.terminus == nil {
                    if let entry = trip.trainId.flatMap({ homeBoard[$0] }) {
                        XCTAssertEqual(NJTParse.servedTerminal(entry.destination), trip.toId, "seed \(seed): \(trip.trainId ?? "?") to \(trip.toId)")
                    }
                }
                let toHoboken = fromHome.filter { $0.toId == "hoboken" }
                let trains = Set(toHoboken.compactMap(\.trainId))
                XCTAssertTrue(cityBound.isSubset(of: trains), "seed \(seed): missing \(cityBound.subtracting(trains).sorted())")
                let state = board(payload, destination: "hoboken")
                XCTAssertEqual(state.hero?.trip.trainId, "6216", "seed \(seed)")
                XCTAssertEqual(state.hero?.expectedDeparture, et("9:18"), "seed \(seed)")
                XCTAssertFalse(state.noService, "seed \(seed)")
            } catch {
                failed += 1
            }
        }
        XCTAssertEqual(refreshed + failed, 150)
        XCTAssertGreaterThan(boardLoaded, 75, "the board should load on most refreshes even at this failure rate")
    }
}

/// A thread-safe counter for transports.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Seeded random failures, shared by concurrent requests.
final class Chaos: @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt64
    private let rate: Double

    init(seed: UInt64, rate: Double) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        self.rate = rate
    }

    private func next() -> Double {
        lock.lock()
        defer { lock.unlock() }
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }

    /// A failed reply about `rate` of the time, else nil.
    func failure() -> NJTHTTPResponse? {
        guard next() < rate else { return nil }
        switch Int(next() * 4) {
        case 0: return NJTHTTPResponse(status: 500, body: Data("{}".utf8))
        case 1: return NJTHTTPResponse(status: 429, body: Data(#"{"message":"Too many requests"}"#.utf8))
        case 2: return NJTHTTPResponse(status: 503, body: Data("<html>Service unavailable</html>".utf8))
        default: return FakeNJT.ok(#"{"errors":[{"message":"Internal server error"}],"data":null}"#)
        }
    }
}
