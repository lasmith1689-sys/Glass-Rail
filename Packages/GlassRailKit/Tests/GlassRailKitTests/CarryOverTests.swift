import Foundation
import XCTest
@testable import GlassRailKit

/// One failed lookup must not fail the whole refresh. Only the direction the
/// board is showing has to refresh; any other direction whose lookup fails
/// keeps its previous trips, dated by their own fetch, so they turn STALE on
/// their own clock and are never shown as fresh.
final class CarryOverTests: XCTestCase {
    /// 9:45 AM EDT, Monday 2026-08-03.
    let base = date("2026-08-03T13:45:00.000Z")
    /// The previous refresh, a minute earlier.
    let earlier = date("2026-08-03T13:44:00.000Z")

    static let toPenn = "Watchung Avenue Station>New York Penn Station"
    static let bayToPenn = "Bay Street Station>New York Penn Station"

    func client(_ fake: FakeNJT, at moment: Date? = nil) -> NJTClient {
        let fixed = moment ?? base
        return NJTClient(transport: fake, clock: { fixed })
    }

    /// Every direction answers with one train, except the lookups listed in
    /// `failing` ("origin>destination"), which get an HTTP 500.
    func feed(failing: Set<String> = [], weekend: Bool = false) -> FakeNJT {
        FakeNJT { operation, variables in
            if operation == "board" { return FakeNJT.emptyBoard }
            let key = "\(variables["origin"].jsString)>\(variables["destination"].jsString)"
            if failing.contains(key) { return NJTHTTPResponse(status: 500, body: Data("{}".utf8)) }
            if weekend {
                // Watchung Avenue has no weekend trains; Bay Street does.
                if key.hasPrefix("Bay Street Station>") { return FakeNJT.planner(train: "1911", at: "10:05:00 AM", arrive: "10:30:00 AM") }
                if key.hasSuffix(">Bay Street Station") { return FakeNJT.planner(train: "1912", at: "10:15:00 AM", arrive: "10:40:00 AM") }
                return FakeNJT.emptyPlanner
            }
            switch key {
            case "Watchung Avenue Station>Hoboken Terminal": return FakeNJT.planner(train: "1082", at: "11:21:00 AM", arrive: "12:00:00 PM")
            case "Hoboken Terminal>Watchung Avenue Station": return FakeNJT.planner(train: "1207", at: "10:21:00 AM", arrive: "11:00:00 AM")
            case Self.toPenn: return FakeNJT.planner(train: "6222", at: "10:01:00 AM", arrive: "10:53:00 AM")
            case "New York Penn Station>Watchung Avenue Station": return FakeNJT.planner(train: "3855", at: "10:11:00 AM", arrive: "11:06:00 AM")
            default: return FakeNJT.emptyPlanner
            }
        }
    }

    /// What the previous refresh (a minute earlier) had.
    var previous: Payload {
        Payload(generatedAt: earlier, source: PayloadSource(kind: .live, detail: "test"), trips: [
            makeTrip(trainId: "1078", departure: date("2026-08-03T14:51:00.000Z"), arrival: date("2026-08-03T15:30:00.000Z")),
            makeTrip(fromId: "hoboken", toId: "watchung", trainId: "1203", departure: date("2026-08-03T14:05:00.000Z"), arrival: date("2026-08-03T14:44:00.000Z")),
            makeTrip(fromId: "watchung", toId: "penn", trainId: "6218", departure: date("2026-08-03T14:31:00.000Z"), arrival: date("2026-08-03T15:23:00.000Z")),
            makeTrip(fromId: "penn", toId: "watchung", trainId: "3851", departure: date("2026-08-03T14:11:00.000Z"), arrival: date("2026-08-03T15:06:00.000Z")),
        ])
    }

    func trains(_ payload: Payload, _ from: String, _ to: String) -> [String?] {
        payload.trips.filter { $0.fromId == from && $0.toId == to }.map(\.trainId)
    }

    // MARK: The client

    func testADirectionOffScreenThatFailsKeepsItsPreviousTripsWithTheirOwnTime() async throws {
        let payload = try await client(feed(failing: [Self.toPenn])).fetchLivePayload(required: ["watchung|hoboken"], previous: previous)
        XCTAssertEqual(payload.source.kind, .live)
        XCTAssertEqual(payload.generatedAt, base)
        XCTAssertEqual(trains(payload, "watchung", "hoboken"), ["1082"], "the direction on screen is fresh")
        XCTAssertEqual(trains(payload, "watchung", "penn"), ["6218"], "the failed direction keeps what it had")
        XCTAssertEqual(payload.carriedOver, ["watchung|penn": earlier])
        XCTAssertNil(payload.unanswered)
        XCTAssertEqual(payload.updatedAt(forPair: "watchung|penn"), earlier)
        XCTAssertEqual(payload.updatedAt(forPair: "watchung|hoboken"), base)
        XCTAssertTrue(payload.isCarriedOver(pair: "watchung|penn"))
        XCTAssertFalse(payload.isCarriedOver(pair: "watchung|hoboken"))
        XCTAssertEqual(
            payload.source.detail,
            "Live NJ Transit feed (partial, earlier trips kept for Watchung Avenue Station to New York Penn Station planner: NJT public feed HTTP 500)."
        )
    }

    func testTheDirectionOnScreenFailingStillFailsTheRefresh() async {
        do {
            _ = try await client(feed(failing: [Self.toPenn])).fetchLivePayload(required: ["watchung|penn"], previous: previous)
            XCTFail("the board must not refresh without the direction it is showing")
        } catch {
            XCTAssertEqual(error as? NJTError, .feed("Watchung Avenue Station to New York Penn Station planner: NJT public feed HTTP 500"))
        }
    }

    func testWithNothingToCarryOverTheDirectionIsUnansweredNeverEmpty() async throws {
        let fake = feed(failing: [Self.toPenn])
        let payload = try await client(fake).fetchLivePayload(required: ["watchung|hoboken"], previous: nil)
        XCTAssertEqual(payload.unanswered, ["watchung|penn"])
        XCTAssertNil(payload.carriedOver)
        XCTAssertNil(payload.updatedAt(forPair: "watchung|penn"))
        XCTAssertTrue(trains(payload, "watchung", "penn").isEmpty)
        // Not mistaken for "no service here": nothing is retried from Bay Street.
        XCTAssertFalse(fake.calls.contains { $0.variables["origin"].jsString == "Bay Street Station" })

        let penn = BoardEngine.compute(BoardInputs(payload: payload, now: base, destinationId: "penn"))
        XCTAssertFalse(penn.noService, "unknown trains are not no trains")
        XCTAssertTrue(penn.unanswered)
        XCTAssertEqual(penn.feedMode, .stale)
        XCTAssertNil(penn.dataUpdatedAt)
        let hoboken = BoardEngine.compute(BoardInputs(payload: payload, now: base, destinationId: "hoboken"))
        XCTAssertEqual(hoboken.feedMode, .live)
        XCTAssertFalse(hoboken.unanswered)
        XCTAssertEqual(hoboken.hero?.trip.trainId, "1082")
    }

    func testSampleDataIsNeverCarriedOverAsLive() async throws {
        let sample = SampleFixture.payload(now: earlier)
        let payload = try await client(feed(failing: [Self.toPenn])).fetchLivePayload(required: ["watchung|hoboken"], previous: sample)
        XCTAssertEqual(payload.unanswered, ["watchung|penn"])
        XCTAssertTrue(trains(payload, "watchung", "penn").isEmpty)
        // The sample itself is never "unanswered": it is labeled SAMPLE instead.
        XCTAssertFalse(BoardEngine.compute(BoardInputs(payload: sample, now: earlier, destinationId: "penn")).unanswered)
    }

    func testCarriedOverAgainKeepsTheOriginalFetchTimeUntilItAnswers() async throws {
        let hoboken: Set<String> = ["watchung|hoboken"]
        let first = try await client(feed(failing: [Self.toPenn]), at: base).fetchLivePayload(required: hoboken, previous: previous)
        let second = try await client(feed(failing: [Self.toPenn]), at: base.addingTimeInterval(60)).fetchLivePayload(required: hoboken, previous: first)
        XCTAssertEqual(second.carriedOver, ["watchung|penn": earlier], "still as old as the refresh that fetched it")
        XCTAssertEqual(trains(second, "watchung", "penn"), ["6218"])

        let third = try await client(feed(), at: base.addingTimeInterval(120)).fetchLivePayload(required: hoboken, previous: second)
        XCTAssertNil(third.carriedOver)
        XCTAssertEqual(third.updatedAt(forPair: "watchung|penn"), base.addingTimeInterval(120))
        XCTAssertEqual(trains(third, "watchung", "penn"), ["6222"])
    }

    func testANearbyStationFailureOffScreenCarriesTheWholeDirection() async throws {
        // Saturday: Watchung Avenue answers with no trains, so each direction
        // is retried from Bay Street, and Bay Street to Penn fails.
        let saturdayBefore = Payload(generatedAt: earlier, source: PayloadSource(kind: .live, detail: "test"), trips: [
            makeTrip(fromId: "baystreet", toId: "penn", trainId: "1915", departure: date("2026-08-03T14:20:00.000Z"), arrival: date("2026-08-03T15:05:00.000Z")),
        ])
        let payload = try await client(feed(failing: [Self.bayToPenn], weekend: true)).fetchLivePayload(required: ["watchung|hoboken"], previous: saturdayBefore)
        XCTAssertEqual(payload.carriedOver, ["watchung|penn": earlier])
        XCTAssertEqual(trains(payload, "baystreet", "penn"), ["1915"], "the nearby station's trains come with their direction")
        XCTAssertEqual(trains(payload, "baystreet", "hoboken"), ["1911"])

        let hoboken = BoardEngine.compute(BoardInputs(payload: payload, now: base, destinationId: "hoboken"))
        XCTAssertTrue(hoboken.noService)
        XCTAssertEqual(hoboken.feedMode, .live)
        XCTAssertEqual(hoboken.alternate?.views.first?.trip.trainId, "1911")
        let penn = BoardEngine.compute(BoardInputs(payload: payload, now: base, destinationId: "penn"))
        XCTAssertTrue(penn.noService, "the earlier answer was no trains, with Bay Street instead")
        XCTAssertEqual(penn.alternate?.views.first?.trip.trainId, "1915")
        XCTAssertEqual(penn.dataUpdatedAt, earlier)

        do {
            _ = try await client(feed(failing: [Self.bayToPenn], weekend: true)).fetchLivePayload(required: ["watchung|penn"], previous: saturdayBefore)
            XCTFail("the nearby station's list is what the board shows, so it must refresh too")
        } catch {
            XCTAssertEqual(error as? NJTError, .feed("Bay Street Station to New York Penn Station planner: NJT public feed HTTP 500"))
        }
    }

    // MARK: The board

    func testCarriedTripsTurnStaleOnTheirOwnClock() {
        let trips = previous.trips
        func state(_ destination: String, carriedAge: TimeInterval) -> BoardState {
            let payload = Payload(generatedAt: base, source: PayloadSource(kind: .live, detail: "test"), trips: trips,
                                  carriedOver: ["watchung|penn": base.addingTimeInterval(-carriedAge)])
            return BoardEngine.compute(BoardInputs(payload: payload, now: base, destinationId: destination))
        }
        let stalePenn = state("penn", carriedAge: 5 * 60)
        XCTAssertEqual(stalePenn.feedMode, .stale)
        XCTAssertEqual(stalePenn.dataUpdatedAt, base.addingTimeInterval(-300))
        XCTAssertEqual(stalePenn.hero?.trip.trainId, "6218", "still shown, but marked outdated")
        XCTAssertFalse(state("penn", carriedAge: 5 * 60).noService)

        let recentPenn = state("penn", carriedAge: 60)
        XCTAssertEqual(recentPenn.feedMode, .live, "a minute-old answer is still live, and says how old it is")
        XCTAssertEqual(recentPenn.dataUpdatedAt, base.addingTimeInterval(-60))

        let hoboken = state("hoboken", carriedAge: 5 * 60)
        XCTAssertEqual(hoboken.feedMode, .live)
        XCTAssertEqual(hoboken.dataUpdatedAt, base)
    }

    func testTheShownPairFollowsTheClockTheDestinationAndAFlip() {
        let morning = date("2026-08-03T13:45:00.000Z")
        let evening = date("2026-08-03T20:00:00.000Z")
        XCTAssertEqual(BoardEngine.shownPair(now: morning, destinationId: "hoboken", modeOverride: nil).key, "watchung|hoboken")
        XCTAssertEqual(BoardEngine.shownPair(now: evening, destinationId: "penn", modeOverride: nil).key, "penn|watchung")
        XCTAssertEqual(BoardEngine.shownPair(now: morning, destinationId: "penn", modeOverride: ModeOverride(mode: .pm, at: morning)).key, "penn|watchung")
        XCTAssertEqual(
            BoardEngine.shownPair(now: morning, destinationId: "hoboken", modeOverride: nil),
            ODPair(fromId: BoardEngine.compute(BoardInputs(payload: previous, now: morning, destinationId: "hoboken")).from.id, toId: "hoboken")
        )
    }
}
