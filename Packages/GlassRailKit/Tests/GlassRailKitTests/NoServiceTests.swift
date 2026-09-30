import Foundation
import XCTest
@testable import GlassRailKit

/// What NJ Transit's trip planner really sends when a window has no trains,
/// captured by CI's njt-probe job from a GitHub runner on Wednesday
/// 2026-09-30 (the planner takes a date, so a weekday run can ask about the
/// weekend):
/// - live-planner-no-trips: Watchung Avenue to Hoboken, Saturday 10/03 at
///   10:00 AM. HTTP 200 with a GraphQL error, "We're sorry. We were unable to
///   find trips between your origin and destination.", and a null schedule.
///   The other three Watchung Avenue directions got the identical reply.
/// - live-planner-saturday-baystreet-hoboken / -hoboken-baystreet /
///   -baystreet-penn / -penn-baystreet: Bay Street at the same moment, which
///   does have weekend trains (to and from Penn with a change at Newark
///   Broad Street).
/// - live-planner-3am-watchung-hoboken / -hoboken-watchung: Thursday 10/01 at
///   3:00 AM. Not a "no trains" reply: the planner answers with the first
///   trains of the morning.
/// - live-planner-bad-station: a made-up origin, same moment. The same shape
///   (HTTP 200, INTERNAL_SERVER_ERROR, null schedule) with a different
///   message, which must stay a failure.
final class NoServiceTests: XCTestCase {
    /// Saturday 2026-10-03, 10:00 AM EDT.
    let saturday = date("2026-10-03T14:00:00.000Z")
    /// Thursday 2026-10-01, 3:00 AM EDT.
    let smallHours = date("2026-10-01T07:00:00.000Z")

    let hobokenPairs = [ODPair(fromId: "watchung", toId: "hoboken"), ODPair(fromId: "hoboken", toId: "watchung")]

    func client(_ fake: FakeNJT, at moment: Date) -> NJTClient {
        NJTClient(transport: fake, clock: { moment })
    }

    /// NJ Transit on that Saturday, from the captured replies.
    func saturdayFeed() -> FakeNJT {
        FakeNJT { operation, variables in
            if operation == "board" { return FakeNJT.emptyBoard }
            switch (variables["origin"].jsString, variables["destination"].jsString) {
            case ("Bay Street Station", "Hoboken Terminal"): return FakeNJT.ok(fixture("live-planner-saturday-baystreet-hoboken"))
            case ("Hoboken Terminal", "Bay Street Station"): return FakeNJT.ok(fixture("live-planner-saturday-hoboken-baystreet"))
            case ("Bay Street Station", "New York Penn Station"): return FakeNJT.ok(fixture("live-planner-saturday-baystreet-penn"))
            case ("New York Penn Station", "Bay Street Station"): return FakeNJT.ok(fixture("live-planner-saturday-penn-baystreet"))
            default: return FakeNJT.ok(fixture("live-planner-no-trips"))
            }
        }
    }

    func expectFailure(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line, check: (Error) -> Void) async {
        do {
            try await work()
            XCTFail("expected a failed lookup", file: file, line: line)
        } catch {
            check(error)
        }
    }

    // MARK: The reply

    func testRecognisesTheCapturedNoTripsReplyAndNothingElse() throws {
        XCTAssertTrue(NJTParse.isNoTripsReply(fixtureJSON("live-planner-no-trips")))

        func reply(_ json: String) throws -> JSON { try JSON.parse(Data(json.utf8)) }
        let message = "We're sorry. We were unable to find trips between your origin and destination."
        // Without a path, the message alone decides.
        XCTAssertTrue(NJTParse.isNoTripsReply(try reply(#"{"errors":[{"message":"\#(message)"}],"data":null}"#)))
        // Any other error is a failure, alone or beside the no-trips one.
        XCTAssertFalse(NJTParse.isNoTripsReply(fixtureJSON("graphql-error")))
        XCTAssertFalse(NJTParse.isNoTripsReply(try reply(#"{"errors":[{"message":"\#(message)"},{"message":"Service unavailable"}],"data":{"getTripPlannerSchedule":null}}"#)))
        XCTAssertFalse(NJTParse.isNoTripsReply(try reply(#"{"errors":[{"message":"Internal server error","path":["getTripPlannerSchedule"]}],"data":{"getTripPlannerSchedule":null}}"#)))
        // The same words about another field, or with itineraries attached, are not this reply.
        XCTAssertFalse(NJTParse.isNoTripsReply(try reply(#"{"errors":[{"message":"\#(message)","path":["getTrainStopList"]}],"data":null}"#)))
        XCTAssertFalse(NJTParse.isNoTripsReply(try reply(#"{"errors":[{"message":"\#(message)"}],"data":{"getTripPlannerSchedule":[{"legs":[]}]}}"#)))
        // No errors at all is not a no-trips reply either (an empty list is read as it is).
        XCTAssertFalse(NJTParse.isNoTripsReply(try reply(#"{"errors":[],"data":null}"#)))
        XCTAssertFalse(NJTParse.isNoTripsReply(try reply(#"{"data":{"getTripPlannerSchedule":[]}}"#)))
    }

    func testTheNoTripsReplyIsAnAnswerWithNoItineraries() async throws {
        let fake = FakeNJT { _, _ in FakeNJT.ok(fixture("live-planner-no-trips")) }
        let list = try await client(fake, at: saturday).fetchTripPlanner(origin: "Watchung Avenue Station", destination: "Hoboken Terminal", at: saturday)
        XCTAssertTrue(list.isEmpty)

        let window = await client(fake, at: saturday).plannerWindow(origin: "Watchung Avenue Station", destination: "Hoboken Terminal")
        XCTAssertEqual(window.lookups, 4)
        XCTAssertEqual(window.failedLookups, [], "no trips is not a failed lookup")
        XCTAssertFalse(window.failed)
        XCTAssertNil(window.reason)
    }

    // MARK: The board

    func testASaturdayAtWatchungAvenueIsNoTrainsWithBayStreetInstead() async throws {
        let fake = saturdayFeed()
        let payload = try await client(fake, at: saturday).fetchLivePayload()
        XCTAssertEqual(payload.source.kind, .live)
        XCTAssertEqual(payload.source.detail, "Live NJ Transit rail planner with origin-board tracks.")
        XCTAssertFalse(payload.trips.contains { $0.fromId == "watchung" || $0.toId == "watchung" })
        XCTAssertTrue(fake.calls.contains { $0.variables["origin"].jsString == "Bay Street Station" }, "retried from Bay Street")

        // Toward the city: "No trains from Watchung Ave", next trains from Bay Street.
        let inbound = BoardEngine.compute(BoardInputs(payload: payload, now: saturday, destinationId: "hoboken"))
        XCTAssertEqual(inbound.dirKey, "watchung|hoboken")
        XCTAssertTrue(inbound.noService)
        XCTAssertEqual(inbound.feedMode, .live)
        XCTAssertNil(inbound.hero)
        XCTAssertEqual(inbound.alternate?.from.id, "baystreet")
        XCTAssertEqual(inbound.alternate?.to.id, "hoboken")
        XCTAssertEqual(inbound.alternate?.views.first?.trip.trainId, "518")
        XCTAssertEqual(inbound.alternate?.views.first?.trip.departure, date("2026-10-03T15:00:00.000Z"))
        XCTAssertEqual(inbound.alternate?.views.first?.trip.arrival, date("2026-10-03T15:38:00.000Z"))

        // Home: no trains to Watchung Ave, next trains to Bay Street.
        let outbound = BoardEngine.compute(BoardInputs(payload: payload, now: saturday, destinationId: "hoboken", modeOverride: ModeOverride(mode: .pm, at: saturday)))
        XCTAssertEqual(outbound.dirKey, "hoboken|watchung")
        XCTAssertTrue(outbound.noService)
        XCTAssertEqual(outbound.feedMode, .live)
        XCTAssertEqual(outbound.alternate?.to.id, "baystreet")
        XCTAssertEqual(outbound.alternate?.views.map(\.trip.trainId), ["519", "523", "527"])
        XCTAssertEqual(outbound.alternate?.views.first?.trip.departure, date("2026-10-03T14:08:00.000Z"))

        // Penn Station the same way, with a change at Newark Broad Street.
        let toPenn = BoardEngine.compute(BoardInputs(payload: payload, now: saturday, destinationId: "penn"))
        XCTAssertEqual(toPenn.dirKey, "watchung|penn")
        XCTAssertTrue(toPenn.noService)
        XCTAssertEqual(toPenn.alternate?.from.id, "baystreet")
        XCTAssertEqual(toPenn.alternate?.to.id, "penn")
        XCTAssertEqual(toPenn.alternate?.views.first?.trip.trainId, "518")
        XCTAssertEqual(toPenn.alternate?.views.first?.trip.transferAt, ["Newark Broad"])
        let fromPenn = BoardEngine.compute(BoardInputs(payload: payload, now: saturday, destinationId: "penn", modeOverride: ModeOverride(mode: .pm, at: saturday)))
        XCTAssertEqual(fromPenn.dirKey, "penn|watchung")
        XCTAssertTrue(fromPenn.noService)
        XCTAssertEqual(fromPenn.alternate?.to.id, "baystreet")
        XCTAssertEqual(fromPenn.alternate?.views.first?.trip.trainId, "6919")
        XCTAssertEqual(fromPenn.alternate?.views.first?.trip.departure, date("2026-10-03T14:11:00.000Z"))
    }

    func testTheSmallHoursShowTheFirstMorningTrainsNotNoService() async throws {
        let fake = FakeNJT { operation, variables in
            if operation == "board" { return FakeNJT.emptyBoard }
            return variables["origin"].jsString == "Watchung Avenue Station"
                ? FakeNJT.ok(fixture("live-planner-3am-watchung-hoboken"))
                : FakeNJT.ok(fixture("live-planner-3am-hoboken-watchung"))
        }
        let payload = try await client(fake, at: smallHours).fetchLivePayload(pairs: hobokenPairs)
        XCTAssertFalse(fake.calls.contains { $0.variables["origin"].jsString == "Bay Street Station" })

        let inbound = BoardEngine.compute(BoardInputs(payload: payload, now: smallHours, destinationId: "hoboken"))
        XCTAssertFalse(inbound.noService)
        XCTAssertEqual(inbound.feedMode, .live)
        XCTAssertEqual(inbound.hero?.trip.trainId, "6200")
        XCTAssertEqual(inbound.hero?.trip.departure, date("2026-10-01T08:48:00.000Z"), "4:48 AM, the same morning")

        let outbound = BoardEngine.compute(BoardInputs(payload: payload, now: smallHours, destinationId: "hoboken", modeOverride: ModeOverride(mode: .pm, at: smallHours)))
        XCTAssertFalse(outbound.noService)
        XCTAssertNotNil(outbound.hero)
    }

    // MARK: Real errors are still failures

    func testAnyOtherPlannerErrorStillFailsTheRefresh() async {
        let fake = FakeNJT { operation, _ in
            operation == "board" ? FakeNJT.emptyBoard : FakeNJT.ok(fixture("graphql-error"))
        }
        await expectFailure({
            _ = try await client(fake, at: saturday).fetchLivePayload(pairs: hobokenPairs)
        }) { error in
            guard case .feed(let message)? = error as? NJTError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.hasPrefix("Watchung Avenue Station to Hoboken Terminal planner: Station not found | Try again"), message)
        }
        // Not mistaken for "no service here": nothing is retried from Bay Street.
        XCTAssertFalse(fake.calls.contains { $0.variables["origin"].jsString == "Bay Street Station" })
    }

    func testTheSameShapedErrorForABadStationIsStillAFailure() async {
        let badStation = fixtureJSON("live-planner-bad-station")
        XCTAssertFalse(NJTParse.isNoTripsReply(badStation))
        let expected = NJTError.graphQL("Cannot destructure property 'latLong' of '(intermediate value)' as it is undefined.")
        let lookup = FakeNJT { _, _ in FakeNJT.ok(fixture("live-planner-bad-station")) }
        await expectFailure({
            _ = try await client(lookup, at: saturday).fetchTripPlanner(origin: "Nowhere Station", destination: "Hoboken Terminal", at: saturday)
        }) { error in
            XCTAssertEqual(error as? NJTError, expected)
        }

        // On the board: one direction answering like that fails the refresh.
        let feed = FakeNJT { operation, variables in
            if operation == "board" { return FakeNJT.emptyBoard }
            if variables["origin"].jsString == "Watchung Avenue Station" && variables["destination"].jsString == "Hoboken Terminal" {
                return FakeNJT.ok(fixture("live-planner-bad-station"))
            }
            return FakeNJT.ok(fixture("live-planner-no-trips"))
        }
        await expectFailure({
            _ = try await client(feed, at: saturday).fetchLivePayload(pairs: hobokenPairs)
        }) { error in
            guard case .feed(let message)? = error as? NJTError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("Watchung Avenue Station to Hoboken Terminal planner: Cannot destructure property"), message)
        }
    }

    func testTheNoTripsWordsOnAnHTTPErrorAreStillAFailure() async {
        let fake = FakeNJT { _, _ in NJTHTTPResponse(status: 500, body: fixture("live-planner-no-trips")) }
        await expectFailure({
            _ = try await client(fake, at: saturday).fetchTripPlanner(origin: "Watchung Avenue Station", destination: "Hoboken Terminal", at: saturday)
        }) { error in
            XCTAssertEqual(error as? NJTError, .http(500))
        }
    }

    func testTheNoTripsWordsBesideAnotherErrorAreStillAFailure() async {
        let fake = FakeNJT { _, _ in
            FakeNJT.ok(#"{"errors":[{"message":"We're sorry. We were unable to find trips between your origin and destination."},{"message":"Upstream timeout"}],"data":{"getTripPlannerSchedule":null}}"#)
        }
        await expectFailure({
            _ = try await client(fake, at: saturday).fetchTripPlanner(origin: "Watchung Avenue Station", destination: "Hoboken Terminal", at: saturday)
        }) { error in
            XCTAssertEqual(error as? NJTError, .graphQL("We're sorry. We were unable to find trips between your origin and destination. | Upstream timeout"))
        }
    }

    func testANullScheduleWithoutAnyErrorIsStillAFailure() async {
        let fake = FakeNJT { _, _ in FakeNJT.ok(#"{"data":null}"#) }
        await expectFailure({
            _ = try await client(fake, at: saturday).fetchTripPlanner(origin: "Watchung Avenue Station", destination: "Hoboken Terminal", at: saturday)
        }) { error in
            XCTAssertEqual(error as? NJTError, .missingData)
        }
    }

    func testAnEmptyAnswerOrANullScheduleWithoutAnErrorIsStillAFailure() async {
        for body in [#"{"data":{}}"#, #"{"data":{"getTripPlannerSchedule":null}}"#, #"{"data":{"getTripPlannerSchedule":"none"}}"#] {
            let fake = FakeNJT { _, _ in FakeNJT.ok(body) }
            await expectFailure({
                _ = try await client(fake, at: saturday).fetchTripPlanner(origin: "Watchung Avenue Station", destination: "Hoboken Terminal", at: saturday)
            }) { error in
                XCTAssertEqual(error as? NJTError, .missingData, body)
            }
        }
    }

    /// Only a fresh answer can say there is no service. When the rider's data
    /// has gone stale (refreshes failing), an empty board means "we don't know",
    /// so it must not claim NJ Transit isn't running or offer hours-old Bay
    /// Street trains.
    func testStaleDataIsNeverReadAsNoService() async throws {
        let payload = try await client(saturdayFeed(), at: saturday).fetchLivePayload()
        let fresh = BoardEngine.compute(BoardInputs(payload: payload, now: saturday, destinationId: "hoboken"))
        XCTAssertTrue(fresh.noService)
        let failing = BoardEngine.compute(BoardInputs(payload: payload, now: saturday, destinationId: "hoboken", fetchFailures: 2))
        XCTAssertEqual(failing.feedMode, .stale)
        XCTAssertFalse(failing.noService)
        XCTAssertNil(failing.alternate)
        let later = BoardEngine.compute(BoardInputs(payload: payload, now: saturday.addingTimeInterval(3 * 3600), destinationId: "hoboken"))
        XCTAssertEqual(later.feedMode, .stale)
        XCTAssertFalse(later.noService)
        XCTAssertNil(later.alternate)
    }
}
