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

    // MARK: Network budget

    func testReusesTheAppsSavedBoardForFiveMinutes() {
        let saved = payload
        XCTAssertTrue(WidgetPlanner.canReuse(saved, now: now))
        XCTAssertTrue(WidgetPlanner.canReuse(saved, now: at(4.99)))
        XCTAssertTrue(WidgetPlanner.canReuse(saved, now: at(5)))
        XCTAssertFalse(WidgetPlanner.canReuse(saved, now: at(5.02)))
        XCTAssertFalse(WidgetPlanner.canReuse(saved, now: at(-6)), "a timestamp from the future is not fresh")
        var sample = saved
        sample.source.kind = .sample
        XCTAssertFalse(WidgetPlanner.canReuse(sample, now: now))
    }

    func testTheWidgetsOwnFetchIsTwoBoardsAndFourPlannerLookups() async throws {
        // 1:30 PM EDT: half an hour before the widget flips to the ride home.
        let base = date("2026-08-03T17:30:00.000Z")
        let fake = FakeNJT { operation, variables in
            if operation == "board" { return FakeNJT.emptyBoard }
            if variables["origin"].jsString == "Hoboken Terminal" {
                return FakeNJT.planner(train: "1159", at: "02:35:00 PM", arrive: "03:14:00 PM")
            }
            return FakeNJT.planner(train: "1101", at: "01:45:00 PM", arrive: "02:24:00 PM")
        }
        let client = NJTClient(transport: fake, clock: { base })
        let payload = try await client.fetchLivePayload(
            pairs: WidgetPlanner.pairs(destinationId: "hoboken"),
            plannerOffsets: WidgetPlanner.plannerOffsetsMinutes
        )
        let planner = fake.calls.filter { $0.operation == "planner" }
        XCTAssertEqual(planner.count, 4)
        XCTAssertEqual(fake.calls.filter { $0.operation == "board" }.count, 2)
        // The ride home is looked up from now, so it is there at 2 PM.
        let homeTimes = planner.filter { $0.variables["origin"].jsString == "Hoboken Terminal" }.map { $0.variables["time"].jsString }
        XCTAssertEqual(Set(homeTimes), ["1:30 PM", "2:45 PM"])

        let timeline = WidgetPlanner.timeline(payload: payload, runs: [:], destinationId: "hoboken", now: base)
        XCTAssertEqual(timeline.first?.commuteMode, .am)
        XCTAssertEqual(timeline.first?.next?.trainId, "1101")
        let twoPM = date("2026-08-03T18:00:00.000Z")
        let afterFlip = timeline.first { $0.date == twoPM }
        XCTAssertEqual(afterFlip?.commuteMode, .pm)
        XCTAssertEqual(afterFlip?.next?.trainId, "1159")
    }

    // MARK: Inline Lock Screen line

    func testTheInlineLineIsShortAndSaysOneThingAfterTheTime() {
        let snapshot = WidgetPlanner.snapshot(payload: payload, runs: [:], destinationId: "hoboken", at: now)
        guard let onTime = snapshot.next, let delayed = snapshot.later.first else {
            return XCTFail("expected trains")
        }
        XCTAssertEqual(onTime.inlineSummary, "1:08 PM · Tk 2")
        XCTAssertEqual(delayed.inlineSummary, "1:43 PM · +5m")

        var cancelled = onTime
        cancelled.cancelled = true
        XCTAssertEqual(cancelled.inlineSummary, "Cancelled 1:08 PM")
        var noTrack = onTime
        noTrack.track = nil
        XCTAssertEqual(noTrack.inlineSummary, "1:08 PM")
        var vague = delayed
        vague.delayMinutes = nil
        XCTAssertEqual(vague.inlineSummary, "1:43 PM · late")

        for line in [onTime, delayed, cancelled].map(\.inlineSummary) {
            XCTAssertLessThanOrEqual(line.count, 17, line)
        }
    }
}
