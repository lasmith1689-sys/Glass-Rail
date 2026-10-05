import XCTest
@testable import GlassRailKit

/// Real NJ Transit replies, captured by CI's njt-probe job from a GitHub
/// runner at about 11:45 AM ET on Tuesday 2026-09-29 (trimmed of GraphQL
/// cache hints). They pin the parser to what the feed actually sends today:
/// bare "11:58 AM" times everywhere, countdown statuses on the board, and a
/// zero-length final planner leg with a null train number.
final class LiveFixtureTests: XCTestCase {
    /// 11:45 AM EDT, when the replies were captured.
    let captured = date("2026-09-29T15:45:00.000Z")

    func et(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").map { Int($0)! }
        return date(String(format: "2026-09-29T%02d:%02d:00.000Z", parts[0] + 4, parts[1]))
    }

    var boardItems: [JSON] { fixtureJSON("live-board-watchung")["data"]?["getTrainDepartureScreens"]?["items"]?.arrayValue ?? [] }
    var itineraries: [JSON] { fixtureJSON("live-planner-watchung-hoboken")["data"]?["getTripPlannerSchedule"]?.arrayValue ?? [] }
    var stopList: [JSON] { fixtureJSON("live-stops-6230")["data"]?["getTrainStopList"]?.arrayValue ?? [] }

    func testReadsTheRealDepartureBoard() {
        let index = NJTParse.buildBoardIndex(boardItems)
        XCTAssertEqual(index.count, 19)
        XCTAssertEqual(index["6230"], BoardEntry(track: "2", note: nil, departureRaw: "11:58 AM", status: nil, destination: "New York -SEC"))
        // "in 23 Min" says nothing about punctuality and is not a note.
        XCTAssertEqual(index["6237"], BoardEntry(track: "1", note: nil, departureRaw: "12:09 PM", status: nil, destination: "MSU"))
        XCTAssertEqual(NJTParse.rawToDate(index["6258"]?.departureRaw ?? "", baseNow: captured), et("18:17"))
    }

    func testNormalizesTheRealPlannerReply() {
        let trips = NJTParse.normalizeItineraries(
            itineraries,
            fromId: "watchung",
            toId: "hoboken",
            boardIndex: NJTParse.buildBoardIndex(boardItems),
            baseNow: captured
        )
        // Two itineraries share train 6230 at 11:58; the earlier arrival wins.
        XCTAssertEqual(trips.map(\.trainId), ["6230", "6234"])

        let first = trips[0]
        XCTAssertEqual(first.departure, et("11:58"))
        XCTAssertEqual(first.arrival, et("13:06"))
        XCTAssertEqual(first.track, "2")
        XCTAssertEqual(first.transferCount, 1)
        XCTAssertEqual(first.transferAt, ["Secaucus"])
        XCTAssertEqual(first.legTrainIds, ["6230", "1114"]) // the null-train final leg is dropped
        XCTAssertEqual(first.note, "Stopover at Secaucus, continue on Train 1114.")
        XCTAssertNil(first.status)

        let second = trips[1]
        XCTAssertEqual(second.departure, et("12:58"))
        XCTAssertEqual(second.arrival, et("14:29"))
        XCTAssertEqual(second.transferAt, ["Newark Broad"])
        XCTAssertEqual(second.legTrainIds, ["6234", "424"])
    }

    func testParsesTheRealStopList() {
        let stops = NJTParse.parseStops(stopList, baseNow: captured)
        XCTAssertEqual(stops.count, 13)
        XCTAssertEqual(stops.first?.name, "Montclair State U")
        XCTAssertEqual(stops.first?.time, et("11:46"))
        XCTAssertEqual(stops.last?.name, "New York Penn Station")
        XCTAssertEqual(stops.last?.time, et("12:44"))
        XCTAssertTrue(stops.allSatisfy { !$0.departed && $0.status == nil && $0.note == nil })
        XCTAssertTrue(Journey.stopMatchesStation(stops[4].name, watchungRef))
        XCTAssertTrue(Journey.stopMatchesStation(stops[12].name, pennRef))
    }

    func testTrueTimesForATransferTripFromRealData() {
        let trip = NJTParse.normalizeItineraries(itineraries, fromId: "watchung", toId: "hoboken",
                                                 boardIndex: NJTParse.buildBoardIndex(boardItems), baseNow: captured)[0]
        let stops = NJTParse.parseStops(stopList, baseNow: captured)
        let timing = Timing.resolveTripTiming(
            stops: stops,
            origin: watchungRef,
            dest: hobokenRef,
            scheduledDeparture: trip.departure,
            scheduledArrival: trip.arrival
        )
        // The stop list says 11:57 for an 11:58 departure: live, not late.
        XCTAssertTrue(timing.pickup.live)
        XCTAssertEqual(timing.pickup.expected, et("11:57"))
        XCTAssertEqual(timing.pickup.delayMinutes, 0)
        // Hoboken is not on 6230's run (it goes to Penn): the drop-off is the timetable.
        XCTAssertEqual(timing.dropoff?.live, false)
        XCTAssertEqual(timing.dropoff?.expected, et("13:06"))

        // The connection is read from the connecting train's own run.
        let connections = Journey.tripConnections(trip, runs: [:])
        XCTAssertEqual(connections.map(\.station), ["Secaucus"])
        XCTAssertEqual(connections.map(\.trainId), ["1114"])
    }
}
