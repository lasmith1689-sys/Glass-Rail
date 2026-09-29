import XCTest
@testable import GlassRailKit

final class WidgetPlannerTests: XCTestCase {
    /// 1:00 PM EDT, an hour before the direction flips.
    let now = date("2026-07-31T17:00:00.000Z")

    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    var payload: Payload {
        Payload(
            generatedAt: now,
            source: PayloadSource(kind: .live, detail: "test"),
            trips: [
                makeTrip(trainId: "1101", departure: at(8), arrival: at(47), track: "2"),
                makeTrip(trainId: "1105", departure: at(38), arrival: at(77), track: nil, status: .delayed, statusNote: "Delayed 5 min"),
                makeTrip(trainId: "1109", departure: at(68), arrival: at(107)),
                makeTrip(fromId: "hoboken", toId: "watchung", trainId: "1290", departure: at(72), arrival: at(111), track: "8"),
                makeTrip(fromId: "hoboken", toId: "watchung", trainId: "1294", departure: at(102), arrival: at(141)),
            ]
        )
    }

    func testEntriesStartNowFollowEachDepartureAndIncludeTheDirectionFlip() {
        let dates = WidgetPlanner.entryDates(payload: payload, runs: [:], destinationId: "hoboken", now: now)
        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, dates.count)
        XCTAssertLessThanOrEqual(dates.count, WidgetPlanner.maxEntries)
        XCTAssertTrue(dates.contains(at(8).addingTimeInterval(61)), "1101 drops off a minute after it leaves")
        XCTAssertTrue(dates.contains(at(60)), "2 PM boundary")
    }

    func testEachEntryShowsTheTrainTheAppWouldShowAtThatMoment() {
        let timeline = WidgetPlanner.timeline(payload: payload, runs: [:], destinationId: "hoboken", now: now)
        XCTAssertEqual(timeline.first?.next?.trainId, "1101")
        XCTAssertEqual(timeline.first?.next?.track, "2")
        XCTAssertEqual(timeline.first?.later.map(\.trainId), ["1105", "1109"])
        XCTAssertEqual(timeline.first?.commuteMode, .am)

        let second = timeline.first { $0.date == at(8).addingTimeInterval(61) }
        XCTAssertEqual(second?.next?.trainId, "1105")
        XCTAssertEqual(second?.next?.delayed, true)
        XCTAssertEqual(second?.next?.delayMinutes, 5)
        XCTAssertEqual(second?.next?.departure, at(43))
        XCTAssertEqual(second?.next?.scheduledDeparture, at(38))

        let afterFlip = timeline.first { $0.date == at(60) }
        XCTAssertEqual(afterFlip?.commuteMode, .pm)
        XCTAssertEqual(afterFlip?.from.id, "hoboken")
        XCTAssertEqual(afterFlip?.next?.trainId, "1290")
    }

    func testFlagsSampleDataAndNoService() {
        var sample = payload
        sample.source.kind = .sample
        XCTAssertTrue(WidgetPlanner.snapshot(payload: sample, runs: [:], destinationId: "hoboken", at: now).isSample)

        let weekend = Payload(generatedAt: now, source: PayloadSource(kind: .live, detail: "test"), trips: [
            makeTrip(fromId: "baystreet", trainId: "1911", departure: at(14), arrival: at(40)),
        ])
        let snapshot = WidgetPlanner.snapshot(payload: weekend, runs: [:], destinationId: "hoboken", at: now)
        XCTAssertTrue(snapshot.noService)
        XCTAssertNil(snapshot.next)
        XCTAssertEqual(snapshot.alternateFrom?.id, "baystreet")
        XCTAssertEqual(snapshot.alternateNext?.trainId, "1911")
    }

    func testReloadsSoonerWhenATrainIsLeavingSoon() {
        let soon = WidgetPlanner.snapshot(payload: payload, runs: [:], destinationId: "hoboken", at: now)
        XCTAssertEqual(WidgetPlanner.reloadDate(now: now, first: soon), at(5))
        let quiet = WidgetPlanner.snapshot(payload: Payload(generatedAt: now, source: payload.source, trips: []), runs: [:], destinationId: "hoboken", at: now)
        XCTAssertEqual(WidgetPlanner.reloadDate(now: now, first: quiet), at(10))
    }

    func testFetchesOnlyTheChosenTerminalsTwoDirectionsAndAFewStopLists() {
        XCTAssertEqual(WidgetPlanner.pairs(destinationId: "penn"), [
            ODPair(fromId: "watchung", toId: "penn"),
            ODPair(fromId: "penn", toId: "watchung"),
        ])
        let ids = WidgetPlanner.trainsNeedingStops(payload: payload, destinationId: "hoboken", now: now)
        XCTAssertEqual(ids, ["1101", "1105", "1109", "1290", "1294"])
        XCTAssertLessThanOrEqual(ids.count, NJTQueries.maxStopListTrains)
    }
}
