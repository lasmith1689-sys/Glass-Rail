import Foundation
import XCTest
@testable import GlassRailKit

/// Stands in for NJ Transit: records every POST body and answers from a handler.
final class FakeNJT: NJTTransport, @unchecked Sendable {
    struct Call {
        var operation: String
        var query: String
        var variables: JSON
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    let handler: @Sendable (_ operation: String, _ variables: JSON) -> NJTHTTPResponse

    init(handler: @escaping @Sendable (_ operation: String, _ variables: JSON) -> NJTHTTPResponse) {
        self.handler = handler
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ body: Data) async throws -> NJTHTTPResponse {
        let object = try JSON.parse(body)
        let query = object["query"].jsString
        let operation: String
        if query.contains("getTripPlannerSchedule") {
            operation = "planner"
        } else if query.contains("getTrainDepartureScreens") {
            operation = "board"
        } else {
            operation = "stops"
        }
        let variables = object["variables"] ?? .null
        lock.lock()
        recorded.append(Call(operation: operation, query: query, variables: variables))
        lock.unlock()
        return handler(operation, variables)
    }

    static func ok(_ json: String) -> NJTHTTPResponse {
        NJTHTTPResponse(status: 200, body: Data(json.utf8))
    }

    static func ok(_ data: Data) -> NJTHTTPResponse {
        NJTHTTPResponse(status: 200, body: data)
    }

    static let emptyBoard = ok(#"{"data":{"getTrainDepartureScreens":{"items":[]}}}"#)
    static let emptyPlanner = ok(#"{"data":{"getTripPlannerSchedule":[]}}"#)

    /// One direct itinerary on `train` at the given Eastern clock time.
    static func planner(train: String, at time: String, arrive: String) -> NJTHTTPResponse {
        ok("""
        {"data":{"getTripPlannerSchedule":[{"duration":"39","legs":[{"routeType":"C","block":"\(train)","onStopDescription":"A","onStopTime":"03-Aug-2026 \(time)","offStopDescription":"B","offStopTime":"03-Aug-2026 \(arrive)"}]}]}}
        """)
    }
}

final class NJTClientTests: XCTestCase {
    let base = date("2026-08-03T13:45:00.000Z")

    func client(_ fake: FakeNJT) -> NJTClient {
        let fixed = base
        return NJTClient(transport: fake, clock: { fixed }, retryDelay: 0)
    }

    // MARK: Requests

    func testSendsV4sExactDepartureBoardQuery() async throws {
        let fake = FakeNJT { _, _ in FakeNJT.emptyBoard }
        _ = try await client(fake).fetchDepartureBoard("Watchung Avenue")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].query, NJTQueries.departureBoard)
        XCTAssertEqual(fake.calls[0].variables, .object(["station": .string("Watchung Avenue")]))
        XCTAssertTrue(NJTQueries.departureBoard.hasPrefix("\n  query DepartureScreen($station: String!) {\n"))
    }

    func testPlannerWindowAsksFourTimesWithV4sVariables() async {
        let fake = FakeNJT { _, _ in FakeNJT.emptyPlanner }
        _ = await client(fake).fetchTripPlannerWindow(origin: "Watchung Avenue Station", destination: "Hoboken Terminal")
        let calls = fake.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(Set(calls.map { $0.variables["time"].jsString }), ["9:45 AM", "11:00 AM", "12:15 PM", "1:30 PM"])
        let first = calls.first { $0.variables["time"].jsString == "9:45 AM" }?.variables
        XCTAssertEqual(first, .object([
            "origin": .string("Watchung Avenue Station"),
            "destination": .string("Hoboken Terminal"),
            "timeOption": .string("D"),
            "date": .string("08/03/2026"),
            "time": .string("9:45 AM"),
            "accessible": .bool(false),
            "travelMode": .string("CTR"),
            "maxWalkingDistance": .string("1.00"),
            "minimizeTime": .string("T"),
        ]))
        XCTAssertEqual(calls[0].query, NJTQueries.tripPlanner)
    }

    // MARK: Errors, in v4's order

    func testReportsHTTPErrors() async {
        let fake = FakeNJT { _, _ in NJTHTTPResponse(status: 503, body: Data(#"{"message":"busy"}"#.utf8)) }
        do {
            _ = try await client(fake).fetchDepartureBoard("Hoboken Terminal")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NJTError, .http(503))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "NJT public feed HTTP 503")
        }
    }

    func testReportsANonJSONBodyBeforeTheStatus() async {
        let fake = FakeNJT { _, _ in NJTHTTPResponse(status: 403, body: Data("<html>Access denied</html>".utf8)) }
        do {
            _ = try await client(fake).fetchDepartureBoard("Hoboken Terminal")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NJTError, .notJSON)
        }
    }

    func testJoinsGraphQLErrorMessages() async {
        let fake = FakeNJT { _, _ in FakeNJT.ok(fixture("graphql-error")) }
        do {
            _ = try await client(fake).fetchTrainStops("1074")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NJTError, .graphQL("Station not found | Try again"))
        }
    }

    func testRejectsAReplyWithoutData() async {
        let fake = FakeNJT { _, _ in FakeNJT.ok(#"{"data":null}"#) }
        do {
            _ = try await client(fake).fetchTrainStops("1074")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NJTError, .missingData)
        }
    }

    // MARK: The whole payload

    func testBuildsTheLivePayloadForAllFourDirections() async throws {
        let boardFixture = fixture("board-watchung")
        let plannerFixture = fixture("planner-watchung-hoboken")
        let fake = FakeNJT { operation, variables in
            if operation == "board" {
                return variables["station"].jsString == "Watchung Avenue" ? FakeNJT.ok(boardFixture) : FakeNJT.emptyBoard
            }
            switch (variables["origin"].jsString, variables["destination"].jsString) {
            case ("Watchung Avenue Station", "Hoboken Terminal"): return FakeNJT.ok(plannerFixture)
            case ("Hoboken Terminal", "Watchung Avenue Station"): return FakeNJT.planner(train: "1207", at: "10:21:00 AM", arrive: "11:00:00 AM")
            case ("Watchung Avenue Station", "New York Penn Station"): return FakeNJT.planner(train: "6222", at: "10:01:00 AM", arrive: "10:53:00 AM")
            case ("New York Penn Station", "Watchung Avenue Station"): return FakeNJT.planner(train: "3855", at: "10:11:00 AM", arrive: "11:06:00 AM")
            default: return FakeNJT.emptyPlanner
            }
        }
        let payload = try await client(fake).fetchLivePayload()

        XCTAssertEqual(payload.source.kind, .live)
        XCTAssertEqual(payload.source.detail, "Live NJ Transit rail planner with origin-board tracks.")
        XCTAssertEqual(payload.generatedAt, base)
        // Pair order, each direction sorted, the planner's four overlapping
        // windows de-duplicated, and every train on Watchung Avenue's board
        // into the city listed both ways (all four run to Hoboken: direct to
        // Hoboken, ending at Hoboken for Penn Station).
        XCTAssertEqual(payload.trips.map { "\($0.fromId)>\($0.toId):\($0.trainId ?? "-")" }, [
            "watchung>hoboken:1074", "watchung>hoboken:1078", "watchung>hoboken:1082", "watchung>hoboken:1086",
            "hoboken>watchung:1207",
            "watchung>penn:1074", "watchung>penn:6222", "watchung>penn:1078", "watchung>penn:1082", "watchung>penn:1086",
            "penn>watchung:3855",
        ])
        XCTAssertEqual(payload.trips.filter { $0.toId == "penn" && $0.trainId != "6222" }.map(\.terminus), ["Hoboken", "Hoboken", "Hoboken", "Hoboken"])
        let calls = fake.calls
        XCTAssertEqual(calls.filter { $0.operation == "board" }.count, 3)
        // Four clock lookups per direction, plus one per train on Watchung
        // Avenue's board (four, all bound for Hoboken) for each way into the city.
        XCTAssertEqual(calls.filter { $0.operation == "planner" }.count, 24)
        XCTAssertEqual(Set(calls.filter { $0.operation == "board" }.map { $0.variables["station"].jsString }),
                       ["Watchung Avenue", "Hoboken Terminal", "New York Penn Station"])
    }

    func testRetriesEmptyDirectionsFromTheNearestStationWithService() async throws {
        let fake = FakeNJT { operation, variables in
            if operation == "board" { return FakeNJT.emptyBoard }
            let origin = variables["origin"].jsString
            let destination = variables["destination"].jsString
            if origin == "Bay Street Station" { return FakeNJT.planner(train: "1911", at: "10:05:00 AM", arrive: "10:30:00 AM") }
            if destination == "Bay Street Station" { return FakeNJT.planner(train: "1912", at: "10:15:00 AM", arrive: "10:40:00 AM") }
            return FakeNJT.emptyPlanner // Watchung Avenue: no weekend service
        }
        let payload = try await client(fake).fetchLivePayload()
        XCTAssertEqual(payload.trips.map { "\($0.fromId)>\($0.toId)" }, [
            "baystreet>hoboken", "hoboken>baystreet", "baystreet>penn", "penn>baystreet",
        ])
        XCTAssertEqual(fake.calls.filter { $0.operation == "planner" }.count, 32)
    }

    func testThrowsOnlyWhenNothingCameBackAndSomethingFailed() async {
        let fake = FakeNJT { _, _ in NJTHTTPResponse(status: 500, body: Data("{}".utf8)) }
        do {
            _ = try await client(fake).fetchLivePayload()
            XCTFail("expected an error")
        } catch {
            guard case .feed(let message)? = error as? NJTError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.hasPrefix("Watchung Avenue board: NJT public feed HTTP 500"), message)
        }
    }

    func testMarksAPartialFeedWhenSomeBoardsFailed() async throws {
        let fake = FakeNJT { operation, variables in
            if operation == "board" {
                return variables["station"].jsString == "Hoboken Terminal" ? NJTHTTPResponse(status: 502, body: Data("{}".utf8)) : FakeNJT.emptyBoard
            }
            return FakeNJT.planner(train: "1074", at: "09:51:00 AM", arrive: "10:30:00 AM")
        }
        let payload = try await client(fake).fetchLivePayload()
        XCTAssertEqual(payload.source.kind, .live)
        XCTAssertEqual(payload.source.detail, "Live NJ Transit feed (partial, some boards unavailable: Hoboken Terminal board: NJT public feed HTTP 502).")
        XCTAssertEqual(payload.trips.count, 4)
    }

    // MARK: Planner outages

    /// Watchung Avenue to Hoboken fails with `failing` for the lookups at the
    /// given Eastern clock times (all of them when nil); everything else answers.
    func outage(times failing: Set<String>?) -> FakeNJT {
        FakeNJT { operation, variables in
            if operation == "board" { return FakeNJT.emptyBoard }
            let origin = variables["origin"].jsString
            let destination = variables["destination"].jsString
            if origin == "Watchung Avenue Station", destination == "Hoboken Terminal" {
                if failing == nil || failing!.contains(variables["time"].jsString) {
                    return NJTHTTPResponse(status: 500, body: Data("{}".utf8))
                }
                return FakeNJT.planner(train: "1082", at: "11:21:00 AM", arrive: "12:00:00 PM")
            }
            return FakeNJT.planner(train: "1207", at: "10:21:00 AM", arrive: "11:00:00 AM")
        }
    }

    func testAPlannerOutageForOneDirectionFailsTheWholeFetch() async {
        let fake = outage(times: nil)
        do {
            _ = try await client(fake).fetchLivePayload()
            XCTFail("an unanswered direction must not come back as a live board with no trains")
        } catch {
            guard case .feed(let message)? = error as? NJTError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(message, "Watchung Avenue Station to Hoboken Terminal planner: NJT public feed HTTP 500")
        }
        // Not mistaken for "no service here": nothing is retried from Bay Street.
        XCTAssertFalse(fake.calls.contains { $0.variables["origin"].jsString == "Bay Street Station" })
    }

    func testAFailedFirstLookupFailsTheDirection() async {
        do {
            _ = try await client(outage(times: ["9:45 AM"])).fetchLivePayload()
            XCTFail("without the first lookup the board would feature a train hours away as next")
        } catch {
            XCTAssertNotNil(error as? NJTError)
        }
    }

    func testLaterLookupFailuresOnlyShortenTheWindow() async throws {
        let payload = try await client(outage(times: ["12:15 PM", "1:30 PM"])).fetchLivePayload()
        XCTAssertEqual(payload.source.kind, .live)
        XCTAssertTrue(payload.trips.contains { $0.fromId == "watchung" && $0.toId == "hoboken" && $0.trainId == "1082" })
    }

    func testThePlannerWindowRecordsWhichLookupsFailed() async {
        let all = await client(outage(times: nil)).plannerWindow(origin: "Watchung Avenue Station", destination: "Hoboken Terminal")
        XCTAssertEqual(all.lookups, 4)
        XCTAssertEqual(all.failedLookups, [0, 1, 2, 3])
        XCTAssertTrue(all.failed)
        XCTAssertEqual(all.reason, "NJT public feed HTTP 500")

        let first = await client(outage(times: ["9:45 AM"])).plannerWindow(origin: "Watchung Avenue Station", destination: "Hoboken Terminal")
        XCTAssertEqual(first.failedLookups, [0])
        XCTAssertTrue(first.failed)

        let later = await client(outage(times: ["11:00 AM"])).plannerWindow(origin: "Watchung Avenue Station", destination: "Hoboken Terminal")
        XCTAssertEqual(later.failedLookups, [1])
        XCTAssertFalse(later.failed)
        XCTAssertEqual(later.itineraries.count, 3)
    }

    func testAnEmptyAnswerIsNoServiceNotAnOutage() async throws {
        let fake = FakeNJT { operation, _ in operation == "board" ? FakeNJT.emptyBoard : FakeNJT.emptyPlanner }
        let payload = try await client(fake).fetchLivePayload()
        XCTAssertEqual(payload.source.kind, .live)
        XCTAssertTrue(payload.trips.isEmpty)
        let state = BoardEngine.compute(BoardInputs(payload: payload, now: base, destinationId: "hoboken"))
        XCTAssertTrue(state.noService, "a planner that answered with nothing is a genuine no-service board")
    }

    func testAnOutageInTheNearbyStationsListAlsoFailsTheFetch() async {
        let fake = FakeNJT { operation, variables in
            if operation == "board" { return FakeNJT.emptyBoard }
            if variables["origin"].jsString == "Bay Street Station" || variables["destination"].jsString == "Bay Street Station" {
                return NJTHTTPResponse(status: 503, body: Data("{}".utf8))
            }
            return FakeNJT.emptyPlanner // Watchung Avenue: no weekend service
        }
        do {
            _ = try await client(fake).fetchLivePayload()
            XCTFail("expected an error")
        } catch {
            guard case .feed(let message)? = error as? NJTError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.hasPrefix("Bay Street Station to Hoboken Terminal planner: NJT public feed HTTP 503"), message)
        }
    }

    // MARK: Per-train lookups

    /// Watchung Avenue's board at 9:45 AM: 1074 (9:51) and 1078 (10:13) into
    /// the city, 6237 (10:09) out to MSU, 6233 gone five minutes ago, and 1090
    /// (2:13 PM) past the clock lookups' reach.
    var homeBoard: [String: BoardEntry] {
        [
            "1074": BoardEntry(track: "2", note: nil, departureRaw: "03-Aug-2026 09:51:00 AM", status: nil, destination: "Hoboken"),
            "1078": BoardEntry(track: "2", note: nil, departureRaw: "03-Aug-2026 10:13:00 AM", status: nil, destination: "New York -SEC"),
            "6237": BoardEntry(track: "1", note: nil, departureRaw: "03-Aug-2026 10:09:00 AM", status: nil, destination: "MSU"),
            "6233": BoardEntry(track: "1", note: nil, departureRaw: "03-Aug-2026 09:40:00 AM", status: nil, destination: "MSU"),
            "1090": BoardEntry(track: "2", note: nil, departureRaw: "03-Aug-2026 02:13:00 PM", status: nil, destination: "Hoboken"),
        ]
    }

    /// Part of that board as NJ Transit sends it.
    static let homeBoardReply = FakeNJT.ok("""
    {"data":{"getTrainDepartureScreens":{"items":[
      {"departureDate":"03-Aug-2026 09:51:00 AM","destination":"Hoboken","status":"","track":"2","trainID":"1074"},
      {"departureDate":"03-Aug-2026 10:13:00 AM","destination":"New York -SEC","status":"","track":"2","trainID":"1078"},
      {"departureDate":"03-Aug-2026 10:09:00 AM","destination":"MSU","status":"","track":"1","trainID":"6237"}
    ]}}}
    """)

    func testSeedsOneLookupPerHomeTrainEachWay() {
        let reach: TimeInterval = 225 * 60
        let into = NJTClient.plannerSeeds(for: ODPair(fromId: "watchung", toId: "hoboken"), homeBoard: homeBoard, now: base, horizon: reach, limit: 8)
        XCTAssertEqual(into, [
            PlannerSeed(at: date("2026-08-03T13:51:00.000Z"), arriveBy: false),
            PlannerSeed(at: date("2026-08-03T14:13:00.000Z"), arriveBy: false),
        ])
        let home = NJTClient.plannerSeeds(for: ODPair(fromId: "penn", toId: "watchung"), homeBoard: homeBoard, now: base, horizon: reach, limit: 8)
        XCTAssertEqual(home, [PlannerSeed(at: date("2026-08-03T14:09:00.000Z"), arriveBy: true)])
        let capped = NJTClient.plannerSeeds(for: ODPair(fromId: "watchung", toId: "hoboken"), homeBoard: homeBoard, now: base, horizon: reach, limit: 1)
        XCTAssertEqual(capped.map(\.at), [date("2026-08-03T13:51:00.000Z")], "the soonest first")
        XCTAssertEqual(NJTClient.plannerSeeds(for: ODPair(fromId: "baystreet", toId: "hoboken"), homeBoard: homeBoard, now: base, horizon: reach, limit: 8), [])
    }

    func testAsksLeaveAtFromHomeAndArriveByForTheRideHome() async throws {
        let fake = FakeNJT { operation, variables in
            if operation == "board" {
                return variables["station"].jsString == "Watchung Avenue" ? Self.homeBoardReply : FakeNJT.emptyBoard
            }
            return FakeNJT.planner(train: "1207", at: "10:21:00 AM", arrive: "11:00:00 AM")
        }
        _ = try await client(fake).fetchLivePayload()
        let clockTimes: Set<String> = ["9:45 AM", "11:00 AM", "12:15 PM", "1:30 PM"]
        let planner = fake.calls.filter { $0.operation == "planner" }
        let seeded = planner.filter { !clockTimes.contains($0.variables["time"].jsString) }.map {
            "\($0.variables["origin"].jsString)>\($0.variables["destination"].jsString) \($0.variables["timeOption"].jsString) \($0.variables["time"].jsString)"
        }
        XCTAssertEqual(Set(seeded), [
            "Watchung Avenue Station>Hoboken Terminal D 9:51 AM",
            "Watchung Avenue Station>Hoboken Terminal D 10:13 AM",
            "Watchung Avenue Station>New York Penn Station D 9:51 AM",
            "Watchung Avenue Station>New York Penn Station D 10:13 AM",
            "Hoboken Terminal>Watchung Avenue Station A 10:09 AM",
            "New York Penn Station>Watchung Avenue Station A 10:09 AM",
        ])
        XCTAssertEqual(seeded.count, 6)
        // The clock lookups still leave from now and every 75 minutes after.
        XCTAssertEqual(planner.count, 16 + 6)
        XCTAssertTrue(planner.filter { clockTimes.contains($0.variables["time"].jsString) }.allSatisfy { $0.variables["timeOption"].jsString == "D" })
    }

    func testTheFirstRefreshLooksUpTrainsOnlyForTheDirectionOnScreen() async throws {
        let fake = FakeNJT { operation, variables in
            if operation == "board" {
                return variables["station"].jsString == "Watchung Avenue" ? Self.homeBoardReply : FakeNJT.emptyBoard
            }
            return FakeNJT.planner(train: "1207", at: "10:21:00 AM", arrive: "11:00:00 AM")
        }
        let njt = client(fake)
        let clockTimes: Set<String> = ["9:45 AM", "11:00 AM", "12:15 PM", "1:30 PM"]
        func seeded() -> [String] {
            fake.calls
                .filter { $0.operation == "planner" && !clockTimes.contains($0.variables["time"].jsString) }
                .map { "\($0.variables["origin"].jsString)>\($0.variables["destination"].jsString)" }
        }

        // Just opened: nothing earlier, so only the board on screen waits on them.
        let first = try await njt.fetchLivePayload(required: ["watchung|hoboken"])
        XCTAssertEqual(seeded(), ["Watchung Avenue Station>Hoboken Terminal", "Watchung Avenue Station>Hoboken Terminal"])

        // A minute later the other directions get theirs; the one on screen comes from cache.
        _ = try await njt.fetchLivePayload(required: ["watchung|hoboken"], previous: first)
        XCTAssertEqual(Set(seeded()), [
            "Watchung Avenue Station>Hoboken Terminal",
            "Watchung Avenue Station>New York Penn Station",
            "Hoboken Terminal>Watchung Avenue Station",
            "New York Penn Station>Watchung Avenue Station",
        ])
        XCTAssertEqual(seeded().count, 2 + 2 + 1 + 1)
    }

    func testATrainBetweenTheClockLookupsComesFromItsOwnLookup() async throws {
        // The clock lookups only ever see 1074; 1078 at 10:13 is found by the
        // lookup pinned to it.
        let fake = FakeNJT { operation, variables in
            if operation == "board" {
                return variables["station"].jsString == "Watchung Avenue" ? Self.homeBoardReply : FakeNJT.emptyBoard
            }
            if variables["origin"].jsString == "Watchung Avenue Station", variables["time"].jsString == "10:13 AM" {
                return FakeNJT.planner(train: "1078", at: "10:13:00 AM", arrive: "10:52:00 AM")
            }
            return FakeNJT.planner(train: "1074", at: "09:51:00 AM", arrive: "10:30:00 AM")
        }
        let payload = try await client(fake).fetchLivePayload(required: ["watchung|hoboken"])
        let into = payload.trips.filter { $0.fromId == "watchung" && $0.toId == "hoboken" }
        XCTAssertEqual(into.compactMap(\.trainId), ["1074", "1078"])
    }

    func testAFailedTrainLookupOnlyCostsThatTrain() async throws {
        let fake = FakeNJT { operation, variables in
            if operation == "board" {
                return variables["station"].jsString == "Watchung Avenue" ? Self.homeBoardReply : FakeNJT.emptyBoard
            }
            if variables["time"].jsString == "10:13 AM" { return NJTHTTPResponse(status: 500, body: Data("{}".utf8)) }
            return FakeNJT.planner(train: "1074", at: "09:51:00 AM", arrive: "10:30:00 AM")
        }
        let payload = try await client(fake).fetchLivePayload()
        XCTAssertEqual(payload.source.kind, .live)
        XCTAssertNil(payload.unanswered)
        XCTAssertNil(payload.carriedOver)
        XCTAssertTrue(payload.trips.contains { $0.fromId == "watchung" && $0.toId == "hoboken" && $0.trainId == "1074" })

        let seeds = NJTClient.plannerSeeds(for: ODPair(fromId: "watchung", toId: "hoboken"), homeBoard: homeBoard, now: base, horizon: 225 * 60, limit: 8)
        let window = await client(fake).plannerWindow(origin: "Watchung Avenue Station", destination: "Hoboken Terminal", seeds: seeds)
        XCTAssertEqual(window.seedLookups, 2)
        XCTAssertEqual(window.failedSeeds, 1)
        XCTAssertEqual(window.failedLookups, [])
        XCTAssertFalse(window.failed)
    }

    func testTrainLookupsAreReusedForTenMinutesClockLookupsAreNot() async throws {
        let clock = MovableClock(base)
        let fake = FakeNJT { operation, variables in
            if operation == "board" {
                return variables["station"].jsString == "Watchung Avenue" ? Self.homeBoardReply : FakeNJT.emptyBoard
            }
            return FakeNJT.planner(train: "1074", at: "09:51:00 AM", arrive: "10:30:00 AM")
        }
        let client = NJTClient(transport: fake, clock: { clock.now })
        let into = [ODPair(fromId: "watchung", toId: "hoboken")]
        _ = try await client.fetchLivePayload(pairs: into)
        clock.now = base.addingTimeInterval(60)
        _ = try await client.fetchLivePayload(pairs: into)
        clock.now = base.addingTimeInterval(11 * 60)
        _ = try await client.fetchLivePayload(pairs: into)

        let planner = fake.calls.filter { $0.operation == "planner" }
        XCTAssertEqual(planner.filter { $0.variables["time"].jsString == "10:13 AM" }.count, 2, "asked, reused a minute later, asked again after ten minutes")
        XCTAssertEqual(planner.filter { $0.variables["time"].jsString == "9:51 AM" }.count, 1, "reused, then that train had left")
        XCTAssertEqual(planner.count, 3 * 4 + 3, "four clock lookups every refresh")
    }

    func testThePlannerCacheForgetsAnswersAfterItsLifetime() {
        let cache = PlannerCache(lifetime: 600)
        cache.store([.string("x")], for: "k", now: base)
        XCTAssertEqual(cache.itineraries(for: "k", now: base.addingTimeInterval(599)), [.string("x")])
        XCTAssertNil(cache.itineraries(for: "k", now: base.addingTimeInterval(600)))
        XCTAssertNil(cache.itineraries(for: "other", now: base))
        cache.store([], for: "k2", now: base.addingTimeInterval(700))
        XCTAssertEqual(cache.count, 1, "expired answers go when a new one is stored")
    }

    // MARK: Stop lists

    func testFetchesRunsSkippingFailuresEmptyListsAndInvalidIds() async {
        let stops = fixture("stops-1074")
        let fake = FakeNJT { _, variables in
            switch variables["train"].jsString {
            case "1074": return FakeNJT.ok(stops)
            case "1078": return NJTHTTPResponse(status: 500, body: Data("{}".utf8))
            default: return FakeNJT.ok(#"{"data":{"getTrainStopList":[]}}"#)
            }
        }
        let runs = await client(fake).fetchTrainRuns(["1074", "bad id!", "1078", "9999", "1074"])
        XCTAssertEqual(Array(runs.keys), ["1074"])
        XCTAssertEqual(runs["1074"]?.count, 5)
        XCTAssertEqual(Set(fake.calls.map { $0.variables["train"].jsString }), ["1074", "1078", "9999"])
    }

    func testCapsARunsBatchAtEightTrains() async {
        let fake = FakeNJT { _, _ in FakeNJT.ok(#"{"data":{"getTrainStopList":[]}}"#) }
        _ = await client(fake).fetchTrainRuns((0..<20).map { String(1000 + $0) })
        XCTAssertEqual(fake.calls.count, 8)
    }
}
