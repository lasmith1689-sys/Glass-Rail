import XCTest
@testable import GlassRailKit

/// The track checker's calls on New York Penn departures: reading its reply,
/// matching a call to a trip, and the board carrying it until NJ Transit
/// posts the track.
final class PennTracksTests: XCTestCase {
    let now = date("2026-10-09T21:40:00.000Z") // 5:40 PM Eastern

    /// The shape penn_board() returns through the penn-tracks function.
    let reply = """
    {"generatedAt": "2026-10-09T21:40:12Z",
     "lastPoll": "2026-10-09T21:40:00Z",
     "departures": [
       {"trainId": "6263", "scheduled": "2026-10-09T21:58:00Z", "track": null,
        "prediction": {"track": "13", "probability": 0.986, "source": "signal", "since": "2026-10-09T21:31:00Z"}},
       {"trainId": "6273", "scheduled": "2026-10-09T22:19:00Z", "track": null,
        "prediction": {"track": "7", "probability": 0.311, "source": "history", "since": "2026-10-09T21:20:00Z"}},
       {"trainId": "3949", "scheduled": "2026-10-09T21:43:00Z", "track": "2", "prediction": null},
       {"trainId": "6283", "scheduled": "not a time", "track": null, "prediction": null}
     ],
     "record": {"signal": {"n": 120, "hits": 118, "medianLeadMinutes": 24.5}}}
    """

    func testReadsTheCheckersReplyAndSkipsWhatItCannotRead() throws {
        let tracks = try PennTracks.parse(Data(reply.utf8))
        XCTAssertEqual(tracks.lastPoll, date("2026-10-09T21:40:00.000Z"))
        XCTAssertEqual(tracks.departures.map(\.trainId), ["6263", "6273", "3949"])
        XCTAssertEqual(tracks.departures[0].call, TrackCall(track: "13", probability: 0.986, source: .signal))
        XCTAssertEqual(tracks.departures[1].call?.source, .history)
        XCTAssertEqual(tracks.departures[2].track, "2")
        XCTAssertNil(tracks.departures[2].call)
        XCTAssertThrowsError(try PennTracks.parse(Data("[]".utf8)))
    }

    func testAlsoReadsTimesWithFractionalSecondsAndAnOffset() throws {
        let tracks = try PennTracks.parse(Data("""
        {"lastPoll": "2026-10-09T21:40:00.123+00:00",
         "departures": [{"trainId": "6263", "scheduled": "2026-10-09T21:58:00+00:00", "track": null, "prediction": null}]}
        """.utf8))
        XCTAssertEqual(tracks.departures.first?.scheduled, date("2026-10-09T21:58:00.000Z"))
        XCTAssertNotNil(tracks.lastPoll)
    }

    func testACallBelongsToTheSameTrainAtTheSameTimeLeavingPenn() throws {
        let tracks = try PennTracks.parse(Data(reply.utf8))
        let departure = date("2026-10-09T21:58:00.000Z")
        let trip = makeTrip(fromId: "penn", toId: "watchung", trainId: "6263", departure: departure, arrival: nil, track: nil)
        XCTAssertEqual(tracks.call(for: trip, now: now)?.track, "13")

        // The board posted a track: its word wins.
        var posted = trip
        posted.track = "12"
        XCTAssertNil(tracks.call(for: posted, now: now))
        // Another train, or the same number on another run.
        XCTAssertNil(tracks.call(for: makeTrip(fromId: "penn", toId: "watchung", trainId: "6265", departure: departure, arrival: nil, track: nil), now: now))
        XCTAssertNil(tracks.call(for: makeTrip(fromId: "penn", toId: "watchung", trainId: "6263", departure: departure.addingTimeInterval(4 * 60), arrival: nil, track: nil), now: now))
        XCTAssertNotNil(tracks.call(for: makeTrip(fromId: "penn", toId: "watchung", trainId: "6263", departure: departure.addingTimeInterval(2 * 60), arrival: nil, track: nil), now: now))
        // Only Penn: the checker knows nothing about Hoboken.
        XCTAssertNil(tracks.call(for: makeTrip(fromId: "hoboken", toId: "watchung", trainId: "6263", departure: departure, arrival: nil, track: nil), now: now))
    }

    func testACheckerThatStoppedPollingCallsNothing() throws {
        let tracks = try PennTracks.parse(Data(reply.utf8))
        let trip = makeTrip(fromId: "penn", toId: "watchung", trainId: "6263", departure: date("2026-10-09T21:58:00.000Z"), arrival: nil, track: nil)
        XCTAssertNotNil(tracks.call(for: trip, now: now.addingTimeInterval(5 * 60)))
        XCTAssertNil(tracks.call(for: trip, now: now.addingTimeInterval(5 * 60 + 1)))
        XCTAssertNil(PennTracks(lastPoll: nil, departures: tracks.departures).call(for: trip, now: now))
    }

    func testThePercentageIsWholeAndNeverCertain() {
        XCTAssertEqual(TrackCall(track: "13", probability: 0.986, source: .signal).percentText, "99%")
        XCTAssertEqual(TrackCall(track: "13", probability: 0.98, source: .signal).percentText, "98%")
        XCTAssertEqual(TrackCall(track: "13", probability: 1, source: .signal).percentText, "99%")
        XCTAssertEqual(TrackCall(track: "7", probability: 0.311, source: .history).percentText, "31%")
        XCTAssertEqual(TrackCall(track: "7", probability: 0.001, source: .history).percentText, "1%")
    }

    func testTheBoardCarriesTheCallForTrainsLeavingPennUntilTheTrackPosts() throws {
        let tracks = try PennTracks.parse(Data(reply.utf8))
        let trips = [
            makeTrip(fromId: "penn", toId: "watchung", trainId: "6263", departure: date("2026-10-09T21:58:00.000Z"), arrival: date("2026-10-09T22:36:00.000Z"), track: nil),
            makeTrip(fromId: "penn", toId: "watchung", trainId: "6273", departure: date("2026-10-09T22:19:00.000Z"), arrival: date("2026-10-09T22:58:00.000Z"), track: nil),
        ]
        let payload = Payload(generatedAt: now, source: PayloadSource(kind: .live, detail: "test"), trips: trips)
        let inputs = BoardInputs(payload: payload, now: now, destinationId: "penn", modeOverride: ModeOverride(mode: .pm, at: now), pennTracks: tracks)
        let state = BoardEngine.compute(inputs)
        XCTAssertEqual(state.from.id, "penn")
        XCTAssertEqual(state.hero?.trackCall?.track, "13")
        XCTAssertEqual(state.later.first?.trackCall?.percentText, "31%")

        // Without the checker the board is as before.
        var without = inputs
        without.pennTracks = nil
        XCTAssertNil(BoardEngine.compute(without).hero?.trackCall)
    }

    func testThePennCallScenarioShowsASignalCallAndAHistoryCall() {
        let payload = Demo.payload(.pennCall, step: 0, now: now)
        let state = BoardEngine.compute(BoardInputs(
            payload: payload, now: now, destinationId: "penn", modeOverride: ModeOverride(mode: .pm, at: now),
            pennTracks: Demo.pennTracks(.pennCall, now: now)
        ))
        XCTAssertEqual(state.hero?.trip.trainId, "6263")
        XCTAssertEqual(state.hero?.trackCall, TrackCall(track: "13", probability: 0.98, source: .signal))
        XCTAssertEqual(state.later.map { $0.trackCall?.percentText }, ["31%", nil])
        XCTAssertNil(Demo.pennTracks(.boarded, now: now))
    }
}
