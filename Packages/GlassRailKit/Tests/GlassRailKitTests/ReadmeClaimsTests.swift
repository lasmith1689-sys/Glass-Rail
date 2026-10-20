import XCTest
@testable import GlassRailKit

/// README claims that had no test of their own: the edges of the windows the
/// README names (a board's 90 minutes back to 6 hours ahead, a train unseen
/// for 6 hours, a ride that left in the last 75 minutes).
final class ReadmeClaimsTests: XCTestCase {
    /// 9:45 AM EDT, Monday 3 August 2026: when the boards were read.
    let fetchedAt = date("2026-08-03T13:45:00.000Z")

    override func setUp() {
        super.setUp()
        HomeStation.override = "watchung"
    }

    override func tearDown() {
        HomeStation.override = nil
        super.tearDown()
    }

    func entry(_ raw: String, to destination: String, track: String? = "2") -> BoardEntry {
        BoardEntry(track: track, note: nil, departureRaw: raw, status: nil, destination: destination)
    }

    // MARK: "Boards add trains, never days": 90 minutes back to 6 hours ahead

    func testABoardsTrainsForTheCityCountFromNinetyMinutesBackToSixHoursAhead() {
        let boards: [String: [String: BoardEntry]] = [
            "watchung": [
                // 91 minutes before the reading: could be another day's.
                "1050": entry("03-Aug-2026 08:14:00 AM", to: "Hoboken"),
                // 89 minutes before: a very late train still counts.
                "1054": entry("03-Aug-2026 08:16:00 AM", to: "Hoboken"),
                // 5 h 59 min ahead.
                "1098": entry("03-Aug-2026 03:44:00 PM", to: "Hoboken"),
                // 6 h 1 min ahead: left to the planner.
                "1102": entry("03-Aug-2026 03:46:00 PM", to: "Hoboken"),
            ],
        ]
        let trips = BoardTruth.reconcile([], pair: ODPair(fromId: "watchung", toId: "hoboken"), boards: boards, fetchedAt: fetchedAt)
        XCTAssertEqual(trips.map(\.trainId), ["1054", "1098"])
        XCTAssertEqual(trips.map(\.departure), [date("2026-08-03T12:16:00.000Z"), date("2026-08-03T19:44:00.000Z")])
        XCTAssertTrue(trips.allSatisfy { $0.fromId == "watchung" && $0.toId == "hoboken" && $0.transferCount == 0 })
        XCTAssertTrue(trips.allSatisfy { $0.listedAt == fetchedAt })
        XCTAssertEqual(BoardTruth.window.back, 90 * 60)
        XCTAssertEqual(BoardTruth.window.ahead, 6 * 3600)
    }

    func testTheRideHomeTrustsTheTerminalsBoardOverTheSameWindow() {
        let boards: [String: [String: BoardEntry]] = [
            // Watchung Avenue's board, heading out of the city: when each gets there.
            "watchung": [
                "6231": entry("03-Aug-2026 08:50:00 AM", to: "MSU", track: "1"),
                "6233": entry("03-Aug-2026 08:52:00 AM", to: "MSU", track: "1"),
                "6299": entry("03-Aug-2026 04:20:00 PM", to: "MSU", track: "1"),
                "6301": entry("03-Aug-2026 04:22:00 PM", to: "MSU", track: "1"),
            ],
            // Hoboken's board: when each leaves.
            "hoboken": [
                "6231": entry("03-Aug-2026 08:14:00 AM", to: "MSU", track: "6"),
                "6233": entry("03-Aug-2026 08:16:00 AM", to: "MSU", track: "6"),
                "6299": entry("03-Aug-2026 03:44:00 PM", to: "MSU", track: "6"),
                "6301": entry("03-Aug-2026 03:46:00 PM", to: "MSU", track: "6"),
            ],
        ]
        let trips = BoardTruth.reconcile([], pair: ODPair(fromId: "hoboken", toId: "watchung"), boards: boards, fetchedAt: fetchedAt)
        XCTAssertEqual(trips.map(\.trainId), ["6233", "6299"])
        XCTAssertEqual(trips.first?.departure, date("2026-08-03T12:16:00.000Z"))
        XCTAssertEqual(trips.first?.arrival, date("2026-08-03T12:52:00.000Z"))
        XCTAssertEqual(trips.last?.departure, date("2026-08-03T19:44:00.000Z"))
        XCTAssertEqual(trips.last?.arrival, date("2026-08-03T20:20:00.000Z"))
        XCTAssertTrue(trips.allSatisfy { $0.fromId == "hoboken" && $0.toId == "watchung" && $0.transferCount == 0 })
    }

    func testTheHomeBoardOnlyAnswersForTheCityWithinThatWindow() {
        func answers(_ raw: String) -> Bool {
            BoardTruth.homeBoardAnswers(["1074": entry(raw, to: "Hoboken")], fetchedAt: fetchedAt)
        }
        XCTAssertFalse(answers("03-Aug-2026 08:14:00 AM"))
        XCTAssertTrue(answers("03-Aug-2026 08:16:00 AM"))
        XCTAssertTrue(answers("03-Aug-2026 03:44:00 PM"))
        XCTAssertFalse(answers("03-Aug-2026 03:46:00 PM"))
        // A train out of the city never answers for the trip into it.
        XCTAssertFalse(BoardTruth.homeBoardAnswers(["6237": entry("03-Aug-2026 10:09:00 AM", to: "MSU")], fetchedAt: fetchedAt))
    }

    // MARK: "A train unseen for 6 hours is forgotten before tracks are compared"

    func testATrainUnseenForSixHoursIsForgottenBeforeTracksAreCompared() {
        /// 5:00 PM EDT, Friday 31 July 2026.
        let seen = date("2026-07-31T21:00:00.000Z")
        let key = "hoboken|watchung|1207"
        func feed(_ track: String, at now: Date) -> Payload {
            let trip = makeTrip(fromId: "hoboken", toId: "watchung", trainId: "1207", departure: now.addingTimeInterval(10 * 60),
                                arrival: now.addingTimeInterval(49 * 60), track: track)
            return Payload(generatedAt: now, source: PayloadSource(kind: .live, detail: "test"), trips: [trip])
        }
        XCTAssertEqual(TrackState.forgetAfter, 6 * 3600)

        // A minute short of six hours: still remembered, so a new track is a change.
        let justUnder = seen.addingTimeInterval(TrackState.forgetAfter - 60)
        var within = TrackState()
        within.ingest(feed("8", at: seen), now: seen)
        within.ingest(feed("6", at: justUnder), now: justUnder)
        XCTAssertEqual(within.changes[key], TrackChange(from: "8", to: "6", detectedAt: justUnder))

        // A minute past six hours: forgotten, so the new track is a first sighting.
        let justOver = seen.addingTimeInterval(TrackState.forgetAfter + 60)
        var past = TrackState()
        past.ingest(feed("8", at: seen), now: seen)
        past.ingest(feed("6", at: justOver), now: justOver)
        XCTAssertTrue(past.changes.isEmpty)
        XCTAssertEqual(past.history[key], "6")

        // Six hours counts from when it was last seen, not first seen.
        var kept = TrackState()
        kept.ingest(feed("8", at: seen), now: seen)
        let again = seen.addingTimeInterval(4 * 3600)
        kept.ingest(feed("8", at: again), now: again)
        let later = seen.addingTimeInterval(8 * 3600)
        kept.ingest(feed("6", at: later), now: later)
        XCTAssertEqual(kept.changes[key], TrackChange(from: "8", to: "6", detectedAt: later))
    }

    // MARK: "On a train that's already left?": the last 75 minutes

    func testOnATrainThatsAlreadyLeftLooksBackSeventyFiveMinutes() {
        /// 9:00 AM EDT, Friday 31 July 2026.
        let now = date("2026-07-31T13:00:00.000Z")
        func ride(_ train: String, leftMinutesAgo: Double) -> Trip {
            // Long rides, all still under way: each gets in 25 minutes from now.
            makeTrip(fromId: "watchung", toId: "hoboken", trainId: train, departure: now.addingTimeInterval(-leftMinutesAgo * 60),
                     arrival: now.addingTimeInterval(25 * 60), track: nil)
        }
        let trips = [ride("5501", leftMinutesAgo: 74), ride("5503", leftMinutesAgo: 76), ride("5505", leftMinutesAgo: 30)]
        let rides = BoardEngine.recentRides(trips, fromId: "watchung", toId: "hoboken", now: now, alerts: true)
        XCTAssertEqual(rides.map(\.trip.trainId), ["5505", "5501"], "most recent first, nothing from before 75 minutes")
        XCTAssertEqual(BoardEngine.recentRideWindow, 75 * 60)
    }
}
