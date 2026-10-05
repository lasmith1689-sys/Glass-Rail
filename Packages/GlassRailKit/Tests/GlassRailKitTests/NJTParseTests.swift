import XCTest
@testable import GlassRailKit

/// The private helpers of lib/njt.ts had no tests in v4; these pin the port's
/// behaviour down against fixtures shaped like NJ Transit's GraphQL replies.
final class NJTParseTests: XCTestCase {
    /// 9:45 AM EDT on Monday 2026-08-03.
    let base = date("2026-08-03T13:45:00.000Z")

    // MARK: Times

    func testParsesTheFullBoardAndPlannerTimeFormatInEasternTime() {
        XCTAssertEqual(NJTParse.rawToDate("03-Aug-2026 09:51:00 AM", baseNow: base), date("2026-08-03T13:51:00.000Z"))
        XCTAssertEqual(NJTParse.rawToDate("03-Aug-2026 12:05:30 PM", baseNow: base), date("2026-08-03T16:05:30.000Z"))
        XCTAssertEqual(NJTParse.rawToDate("3-Aug-2026 12:00:00 AM", baseNow: base), date("2026-08-03T04:00:00.000Z"))
        // Winter: EST is UTC-5.
        XCTAssertEqual(NJTParse.rawToDate("15-Jan-2026 05:08:00 PM", baseNow: base), date("2026-01-15T22:08:00.000Z"))
    }

    func testParsesATimeOnlyStringAsTodayInEasternTime() {
        XCTAssertEqual(NJTParse.rawToDate("9:57 AM", baseNow: base), date("2026-08-03T13:57:00.000Z"))
        XCTAssertEqual(NJTParse.rawToDate("10:32AM", baseNow: base), date("2026-08-03T14:32:00.000Z"))
        XCTAssertEqual(NJTParse.rawToDate("1:05 pm", baseNow: base), date("2026-08-03T17:05:00.000Z"))
        // A few hours in the past is still today (a late train's stop).
        XCTAssertEqual(NJTParse.rawToDate("6:00 AM", baseNow: base), date("2026-08-03T10:00:00.000Z"))
    }

    func testRollsATimeOnlyStringMoreThan8HoursInThePastToTomorrow() {
        let lateEvening = date("2026-08-03T03:30:00.000Z") // 11:30 PM ET, Aug 2
        XCTAssertEqual(NJTParse.rawToDate("12:10 AM", baseNow: lateEvening), date("2026-08-03T04:10:00.000Z"))
        XCTAssertEqual(NJTParse.rawToDate("11:50 PM", baseNow: lateEvening), date("2026-08-03T03:50:00.000Z"))
    }

    func testRejectsTimesV4CouldNotParse() {
        XCTAssertNil(NJTParse.rawToDate("", baseNow: base))
        XCTAssertNil(NJTParse.rawToDate("garbage", baseNow: base))
        XCTAssertNil(NJTParse.rawToDate("03-AUG-2026 09:51:00 AM", baseNow: base)) // month lookup is case-sensitive
        XCTAssertNil(NJTParse.rawToDate("03-Aug-2026 09:51:00 am", baseNow: base)) // full format wants AM/PM
        XCTAssertNil(NJTParse.rawToDate("2026-08-03T13:51:00Z", baseNow: base))
    }

    func testBuildsThePlannerDateAndTimeFieldsInEasternTime() {
        XCTAssertEqual(NJTParse.plannerMoment(base).date, "08/03/2026")
        XCTAssertEqual(NJTParse.plannerMoment(base).time, "9:45 AM")
        XCTAssertEqual(NJTParse.plannerMoment(date("2026-08-03T16:00:00.000Z")).time, "12:00 PM")
        XCTAssertEqual(NJTParse.plannerMoment(date("2026-08-04T03:59:00.000Z")).date, "08/03/2026") // 11:59 PM ET
        XCTAssertEqual(NJTParse.plannerMoment(date("2026-08-04T04:01:00.000Z")).time, "12:01 AM")
    }

    // MARK: Text and boards

    func testCleanStripsEntitiesTagsAndExtraWhitespace() {
        XCTAssertEqual(NJTParse.clean(" Hoboken &#9992; "), "Hoboken")
        XCTAssertEqual(NJTParse.clean("Bus &amp; rail"), "Bus & rail")
        XCTAssertEqual(NJTParse.clean("<b>DELAYED</b>\n  now"), "DELAYED now")
        XCTAssertEqual(NJTParse.clean(JSON.number(1082)), "1082")
        XCTAssertEqual(NJTParse.clean(JSON.null), "")
        XCTAssertEqual(NJTParse.clean(nil as JSON?), "")
    }

    func testBuildsTheBoardIndexFirstEntryWinsAndCountdownsAreNotNotes() {
        let items = fixtureJSON("board-watchung")["data"]?["getTrainDepartureScreens"]?["items"]?.arrayValue ?? []
        let index = NJTParse.buildBoardIndex(items)
        XCTAssertEqual(Set(index.keys), ["1074", "1078", "1082", "1086"])

        XCTAssertEqual(index["1074"], BoardEntry(track: "2", note: nil, departureRaw: "03-Aug-2026 09:51:00 AM", status: nil, destination: "Hoboken", countdownMinutes: 5))
        XCTAssertEqual(index["1078"], BoardEntry(track: "1", note: "Delayed 6 min · DELAYED", departureRaw: "03-Aug-2026 10:13:00 AM", status: .delayed, destination: "Hoboken"))
        XCTAssertEqual(index["1082"]?.status, .cancelled)
        XCTAssertEqual(index["1082"]?.note, "Bus & rail · Cancelled")
        XCTAssertNil(index["1082"]?.track)
        XCTAssertEqual(index["1086"], BoardEntry(track: nil, note: nil, departureRaw: "03-Aug-2026 11:13:00 AM", status: .onTime, destination: "Hoboken"))
    }

    func testTellsTrainsBoundForTheCityFromTrainsLeavingIt() {
        XCTAssertTrue(NJTParse.isTowardCity("Hoboken"))
        XCTAssertTrue(NJTParse.isTowardCity("New York -SEC"))
        XCTAssertFalse(NJTParse.isTowardCity("MSU"))
        XCTAssertFalse(NJTParse.isTowardCity("MSU -SEC"), "-SEC only means via Secaucus")
        XCTAssertFalse(NJTParse.isTowardCity("Hackettstown"))
        XCTAssertFalse(NJTParse.isTowardCity(nil))
    }

    /// One planner leg as NJ Transit sends it (missing fields come back null).
    func leg(_ type: String, _ block: String?, _ on: String, _ onTime: String?, _ off: String, _ offTime: String?) -> JSON {
        .object([
            "routeType": .string(type),
            "block": block.map(JSON.string) ?? .null,
            "onStopDescription": .string(on),
            "onStopTime": onTime.map(JSON.string) ?? .null,
            "offStopDescription": .string(off),
            "offStopTime": offTime.map(JSON.string) ?? .null,
        ])
    }

    /// The shape of a live answer for Watchung Avenue to New York Penn Station
    /// on a weekday morning: train 1000 to Hoboken, then PATH to 33rd St.
    /// Read as rail alone it looked like a direct trip arriving at 7:42, when
    /// the train reaches Hoboken; the all-rail way for the same train is the
    /// one to show.
    func testLeavesOutTripsThatRidePATHOrTheSubway() {
        let itineraries: [JSON] = [
            .object(["legs": .array([
                leg("C", "1000", "WATCHUNG AVENUE", "7:08 AM", "HOBOKEN", "7:42 AM"),
                leg("W", nil, "HOBOKEN", "7:42 AM", "HOBOKEN PATH STATION", nil),
                leg("T", "114991", "HOBOKEN PATH STATION", "7:53 AM", "33RD ST PATH", "8:08 AM"),
            ])]),
            .object(["legs": .array([
                leg("C", "1000", "WATCHUNG AVENUE", "7:08 AM", "NEWARK BROAD ST", "7:30 AM"),
                leg("C", "6612", "NEWARK BROAD ST", "7:38 AM", "NEW YORK PENN STATION", "8:03 AM"),
            ])]),
        ]
        XCTAssertTrue(NJTParse.usesOtherTransit(itineraries[0]["legs"]?.arrayValue))
        XCTAssertFalse(NJTParse.usesOtherTransit(itineraries[1]["legs"]?.arrayValue))

        let trips = NJTParse.normalizeItineraries(itineraries, fromId: "watchung", toId: "penn", boardIndex: [:], baseNow: base)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.trainId, "1000")
        XCTAssertEqual(trips.first?.transferAt, ["Newark Broad"])
        XCTAssertEqual(trips.first?.arrival, date("2026-08-03T12:03:00.000Z"), "8:03 AM at Penn, not 7:42 at Hoboken")
    }

    // MARK: Itineraries

    func testPrettifiesStopNamesForTransferNotes() {
        XCTAssertEqual(NJTParse.prettifyStop(.string("NEWARK BROAD ST UPPER LEVEL")), "Newark Broad")
        XCTAssertEqual(NJTParse.prettifyStop(.string("SECAUCUS UPPER LEVEL")), "Secaucus")
        XCTAssertEqual(NJTParse.prettifyStop(.string("PENN STATION NEW YORK")), "Penn Station NY")
        XCTAssertEqual(NJTParse.prettifyStop(.string("NEW YORK PENN STATION")), "Penn Station NY")
        XCTAssertEqual(NJTParse.prettifyStop(.string("HOBOKEN TERMINAL")), "Hoboken")
        XCTAssertEqual(NJTParse.prettifyStop(.string("WATCHUNG AVENUE")), "Watchung Ave")
        XCTAssertEqual(NJTParse.prettifyStop(.string("WAYNE-ROUTE 23 TRANSIT CENTER")), "Wayne-Route 23 Transit Center")
        XCTAssertEqual(NJTParse.prettifyStop(.string("  ")), "your connection")
        XCTAssertEqual(NJTParse.prettifyStop(nil), "your connection")
    }

    func testNormalizesPlannerItinerariesIntoOneTripPerTrainAndDeparture() {
        let itineraries = fixtureJSON("planner-watchung-hoboken")["data"]?["getTripPlannerSchedule"]?.arrayValue ?? []
        let boardItems = fixtureJSON("board-watchung")["data"]?["getTrainDepartureScreens"]?["items"]?.arrayValue ?? []
        let trips = NJTParse.normalizeItineraries(
            itineraries,
            fromId: "watchung",
            toId: "hoboken",
            boardIndex: NJTParse.buildBoardIndex(boardItems),
            baseNow: base
        )
        // The walk leg, the bus-only trip and the leg without a time drop out;
        // the transfer duplicate of 1074 loses to the direct itinerary.
        XCTAssertEqual(trips.map(\.trainId), ["1074", "1078", "1082"])

        let direct = trips[0]
        XCTAssertEqual(direct.departure, date("2026-08-03T13:51:00.000Z"))
        XCTAssertEqual(direct.arrival, date("2026-08-03T14:30:00.000Z"))
        XCTAssertEqual(direct.track, "2")
        XCTAssertEqual(direct.transferCount, 0)
        XCTAssertEqual(direct.transferAt, [])
        XCTAssertEqual(direct.legTrainIds, ["1074"])
        XCTAssertNil(direct.note)
        XCTAssertNil(direct.status)
        XCTAssertNil(direct.statusNote)

        let transfer = trips[1]
        XCTAssertEqual(transfer.transferCount, 1)
        XCTAssertEqual(transfer.transferAt, ["Newark Broad"])
        XCTAssertEqual(transfer.legTrainIds, ["1078", "6226"])
        XCTAssertEqual(transfer.arrival, date("2026-08-03T15:09:00.000Z"))
        XCTAssertEqual(transfer.track, "1")
        XCTAssertEqual(transfer.status, .delayed)
        XCTAssertEqual(transfer.statusNote, "Delayed 6 min · DELAYED")
        XCTAssertEqual(transfer.note, "Stopover at Newark Broad, continue on Train 6226. Delayed 6 min · DELAYED")

        let cancelled = trips[2]
        XCTAssertEqual(cancelled.trainId, "1082") // a numeric block still reads as the train number
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertNil(cancelled.track)
    }

    func testTransferNoteFallsBackToThePreviousLegsOffStop() {
        let legs: [JSON] = [
            .object(["routeType": .string("C"), "block": .string("1074"), "onStopTime": .string("x"), "offStopTime": .string("y"), "offStopDescription": .string("NEWARK BROAD ST UPPER LEVEL")]),
            .object(["routeType": .string("C"), "block": .string("6222"), "onStopTime": .string("x"), "offStopTime": .string("y"), "onStopDescription": .string("")]),
        ]
        XCTAssertEqual(NJTParse.buildTransferNote(legs), "Stopover at Newark Broad, continue on Train 6222.")
        XCTAssertEqual(NJTParse.transferStops(legs), ["Newark Broad"])
        XCTAssertNil(NJTParse.buildTransferNote(Array(legs.prefix(1))))
        XCTAssertEqual(NJTParse.transferStops(Array(legs.prefix(1))), [])
    }

    func testPrefersFewerTransfersThenEarlierArrivalThenShorterNote() {
        let t0 = date("2026-08-03T13:51:00.000Z")
        let direct = makeTrip(departure: t0, arrival: t0.addingTimeInterval(2400))
        var transfer = direct
        transfer.transferCount = 1
        XCTAssertLessThan(NJTParse.compareTripPreference(direct, transfer), 0)

        var later = direct
        later.arrival = t0.addingTimeInterval(3000)
        XCTAssertLessThan(NJTParse.compareTripPreference(direct, later), 0)

        var noArrival = direct
        noArrival.arrival = nil
        XCTAssertLessThan(NJTParse.compareTripPreference(direct, noArrival), 0)

        var noisy = direct
        noisy.note = "Stopover at Secaucus."
        XCTAssertLessThan(NJTParse.compareTripPreference(direct, noisy), 0)
        XCTAssertEqual(NJTParse.compareTripPreference(direct, direct), 0)
    }

    // MARK: Stop lists

    func testParsesAStopListWithLiveDepartedFlagsAndBoardingNotes() {
        let list = fixtureJSON("stops-1074")["data"]?["getTrainStopList"]?.arrayValue ?? []
        let stops = NJTParse.parseStops(list, baseNow: base)
        XCTAssertEqual(stops.map(\.name), ["Montclair State U", "Upper Montclair", "Watchung Avenue", "Bay Street", "Hoboken"])
        XCTAssertEqual(stops[0], TrainStop(name: "Montclair State U", time: date("2026-08-03T13:42:00.000Z"), departed: true, status: "OnTime", note: nil))
        XCTAssertEqual(stops[2].time, date("2026-08-03T13:57:00.000Z"))
        XCTAssertNil(stops[3].time) // unparseable time
        XCTAssertFalse(stops[3].departed) // only a real `true` counts
        XCTAssertNil(stops[3].status)
        XCTAssertEqual(stops[4].note, "Discharge Only")
        XCTAssertEqual(stops[4].time, date("2026-08-03T14:32:00.000Z"))
    }
}
