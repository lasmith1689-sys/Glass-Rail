import Foundation

/// Port of lib/status.ts: the operational state of each trip, derived purely.
public enum FeedMode: String, Sendable, Hashable {
    case live
    case stale
    case sample
}

public struct TrackChange: Codable, Equatable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var detectedAt: Date

    public init(from: String, to: String, detectedAt: Date) {
        self.from = from
        self.to = to
        self.detectedAt = detectedAt
    }
}

public struct TripView: Equatable, Sendable {
    public var trip: Trip
    public var key: String?
    public var delayed: Bool
    public var delayMinutes: Int?
    /// Scheduled departure shifted by the parsed delay; equals the schedule when no delay info.
    public var expectedDeparture: Date
    public var expectedArrival: Date?
    public var cancelled: Bool
    public var trackChange: TrackChange?
    /// True pickup/drop-off times, attached by `withTiming` when stop data exists.
    public var timing: TripTiming?
    /// The origin's departure board still lists the train past
    /// `expectedDeparture`, so it may still be boarding: it stays on screen
    /// until this time without its time being changed (the time shown is
    /// always the live one; trains do leave early).
    public var holdUntil: Date?
    /// Leaving New York Penn with no posted track yet: the track checker's
    /// call on it, with how likely it is (see `PennTracks`).
    public var trackCall: TrackCall?

    public init(
        trip: Trip,
        key: String?,
        delayed: Bool,
        delayMinutes: Int?,
        expectedDeparture: Date,
        expectedArrival: Date?,
        cancelled: Bool,
        trackChange: TrackChange?,
        timing: TripTiming? = nil,
        holdUntil: Date? = nil,
        trackCall: TrackCall? = nil
    ) {
        self.trip = trip
        self.key = key
        self.delayed = delayed
        self.delayMinutes = delayMinutes
        self.expectedDeparture = expectedDeparture
        self.expectedArrival = expectedArrival
        self.cancelled = cancelled
        self.trackChange = trackChange
        self.timing = timing
        self.holdUntil = holdUntil
        self.trackCall = trackCall
    }
}

public enum Status {
    /// Live payload older than this is downgraded to "stale" (a few missed 60 s refreshes).
    public static let staleAfter: TimeInterval = 210
    /// How long a track-change alert stays visible before the new track becomes the quiet normal.
    public static let trackChangeTTL: TimeInterval = 10 * 60
    /// A train stays listed this long past its (expected) departure: it may still be boarding.
    public static let departureGrace: TimeInterval = 60
    /// A pinned ride stays featured this long past its expected arrival.
    public static let rideArrivalGrace: TimeInterval = 3 * 60
    /// Without an arrival time, a pinned ride is retained at most this long after departure.
    public static let rideNoArrivalTTL: TimeInterval = 90 * 60

    /// `generatedAt` is nil when the payload's timestamp could not be read,
    /// which is never presented as live.
    public static func deriveFeedMode(
        kind: SourceKind,
        generatedAt: Date?,
        now: Date,
        consecutiveFailures: Int = 0
    ) -> FeedMode {
        if kind != .live { return .sample }
        if consecutiveFailures >= 2 { return .stale }
        guard let generatedAt else { return .stale }
        return now.timeIntervalSince(generatedAt) > staleAfter ? .stale : .live
    }

    /// NJT boards phrase delays as e.g. "Delayed 10 min" / "Running 15 min late".
    /// Minutes are only trusted when the note actually talks about a delay and the
    /// number is plausible; anything else yields nil (delayed, magnitude unknown).
    public static func parseDelayMinutes(_ note: String?) -> Int? {
        guard let note, !note.isEmpty, RX.test("delay|late", note, ignoreCase: true) else { return nil }
        guard let match = RX.match("(\\d+)\\s*min", note, ignoreCase: true), let minutes = Int(match[1]) else {
            return nil
        }
        if minutes < 1 || minutes > 240 { return nil }
        return minutes
    }

    /// Shift a time by whole minutes; passes through when there is nothing to shift.
    public static func shift(_ date: Date?, minutes: Int?) -> Date? {
        guard let date, let minutes else { return date }
        return date.adding(minutes: minutes)
    }

    /// Stable identity for comparing refreshes: direction pair + NJT train number.
    public static func tripKey(_ trip: Trip) -> String? {
        guard let trainId = trip.trainId, !trainId.isEmpty else { return nil }
        return "\(trip.fromId)|\(trip.toId)|\(trainId)"
    }

    /// When the origin's departure board says this train really leaves: its
    /// countdown after `listedAt` ("in 7 Min" read at 9:11 is 9:18), which is
    /// exact; or, for a train still listed after its timetable time with no
    /// countdown, a minute after `listedAt`, which only says it hasn't gone.
    /// nil when the board didn't list it.
    public static func boardDeparture(_ trip: Trip) -> (time: Date, exact: Bool)? {
        guard let listedAt = trip.listedAt else { return nil }
        if let minutes = trip.countdownMinutes { return (listedAt.adding(minutes: minutes), true) }
        if trip.departure < listedAt { return (listedAt.addingTimeInterval(60), false) }
        return nil
    }

    /// A train counts as late from this many minutes behind its timetable.
    public static let lateAfterMinutes = 2

    /// Derive the display state for one trip. `alerts` is false for sample
    /// payloads: fixture data must never surface delays, cancellations, or
    /// track changes as though they were real.
    ///
    /// A late train is caught two ways: NJ Transit's delay text ("Delayed 10
    /// min"), and the board's countdown, which runs to the real departure, so
    /// "in 10 Min" on a train due now means it is 10 minutes late even when
    /// there is no text. On 5 October 2026 train 6216, due at 9:05, read "in 7
    /// Min" at 9:11 with no delay text; going by the timetable alone it left
    /// the board while it was still on its way.
    public static func deriveTripView(_ trip: Trip, changes: [String: TrackChange], alerts: Bool) -> TripView {
        let key = tripKey(trip)
        var delayed = alerts && trip.status == .delayed
        var delayMinutes = delayed ? parseDelayMinutes(trip.statusNote) : nil
        var expectedDeparture = shift(trip.departure, minutes: delayMinutes) ?? trip.departure
        var lateBy = delayMinutes
        var holdUntil: Date?
        if alerts, let board = boardDeparture(trip) {
            if board.exact {
                // A countdown runs to the real departure.
                if board.time > expectedDeparture {
                    expectedDeparture = board.time
                    let late = jsRound(expectedDeparture.timeIntervalSince(trip.departure) / 60)
                    if late >= lateAfterMinutes {
                        delayed = true
                        lateBy = late
                        delayMinutes = late
                    }
                }
            } else if let listedAt = trip.listedAt {
                // Still listed past its time with no countdown: late by an
                // unknown amount. It keeps its timetable time rather than a
                // made-up one, and stays on screen while the board lists it.
                holdUntil = board.time
                if jsRound(listedAt.timeIntervalSince(trip.departure) / 60) >= lateAfterMinutes {
                    delayed = true
                }
            }
        }
        return TripView(
            trip: trip,
            key: key,
            delayed: delayed,
            delayMinutes: delayMinutes,
            expectedDeparture: expectedDeparture,
            expectedArrival: shift(trip.arrival, minutes: lateBy),
            cancelled: alerts && trip.status == .cancelled,
            trackChange: (alerts && key != nil) ? changes[key!] : nil,
            holdUntil: holdUntil
        )
    }

    /// Fold a freshly fetched (live) trip list into the per-train track history.
    /// A change is reported only when the same train's track differs from the
    /// last track we successfully displayed; the first sighting never counts.
    /// A temporarily missing track keeps the previous value.
    public static func updateTrackHistory(
        _ history: [String: String],
        trips: [Trip],
        now: Date
    ) -> (history: [String: String], changes: [String: TrackChange]) {
        var next = history
        var changes: [String: TrackChange] = [:]
        for trip in trips {
            guard let key = tripKey(trip), let track = trip.track, !track.isEmpty else { continue }
            if let previous = next[key], previous != track {
                changes[key] = TrackChange(from: previous, to: track, detectedAt: now)
            }
            next[key] = track
        }
        return (next, changes)
    }

    public static func pruneTrackChanges(_ changes: [String: TrackChange], now: Date) -> [String: TrackChange] {
        changes.filter { now.timeIntervalSince($0.value.detectedAt) <= trackChangeTTL }
    }

    /// Upcoming trips for one direction, ordered by when they actually leave.
    /// Filtering and ordering use the expected (delay-shifted) departure so a
    /// delayed train neither vanishes while still catchable nor blocks an
    /// on-time train that will leave before it. `timing` (live stop-list
    /// times) is applied before that filter, so a train whose live stop time
    /// is still ahead stays even when its timetable time has passed.
    public static func selectTripViews(
        _ trips: [Trip],
        fromId: String,
        toId: String,
        now: Date,
        alerts: Bool,
        changes: [String: TrackChange],
        timing: (TripView) -> TripView = { $0 }
    ) -> [TripView] {
        let cutoff = now.addingTimeInterval(-departureGrace)
        return trips
            .filter { $0.fromId == fromId && $0.toId == toId }
            .map { timing(deriveTripView($0, changes: changes, alerts: alerts)) }
            .filter { max($0.expectedDeparture, $0.holdUntil ?? $0.expectedDeparture) >= cutoff }
            .stableSorted { $0.expectedDeparture < $1.expectedDeparture }
    }

    /// Drops a connection nobody should take: another trip this way leaves no
    /// earlier and arrives no later, and beats it on one of the two. NJ
    /// Transit offers many ways to catch the same train home (from Hoboken via
    /// Secaucus at 6:14, 6:17 and 6:20, all reaching Watchung at 7:23, when
    /// the 6:38 via Newark Broad does too); only the 6:38 earns a row. Direct
    /// trains always stay, so every train that runs this way is listed, and
    /// so does the trip with `keeping`'s key (the pinned one). A cancelled
    /// trip never counts as the better option. Times are the expected
    /// (delay-shifted) ones; a trip without an arrival is never compared.
    public static func hidingDominatedConnections(_ views: [TripView], keeping: String? = nil) -> [TripView] {
        let rivals = views.filter { !$0.cancelled && $0.expectedArrival != nil }
        return views.filter { view in
            guard view.trip.transferCount > 0, let arrival = view.expectedArrival else { return true }
            if let keeping, view.key == keeping { return true }
            return !rivals.contains { other in
                guard let otherArrival = other.expectedArrival else { return false }
                let leavesNoEarlier = other.expectedDeparture >= view.expectedDeparture
                let arrivesNoLater = otherArrival <= arrival
                let better = other.expectedDeparture > view.expectedDeparture || otherArrival < arrival
                return leavesNoEarlier && arrivesNoLater && better
            }
        }
    }

    /// The trip to show for a pinned ride. NJ Transit's planner only returns
    /// future departures, so the train the rider is sitting on disappears
    /// from the payload the moment it leaves. Prefer fresh feed data, fall back
    /// to the last trip we saw.
    public static func retainRideTrip(cached: Trip?, trips: [Trip], key: String) -> Trip? {
        if let fresh = trips.first(where: { tripKey($0) == key }) { return fresh }
        if let cached, tripKey(cached) == key { return cached }
        return nil
    }

    /// A pinned trip rendered as the hero. Unlike `selectTripViews`, a departed
    /// trip is kept until shortly after its expected arrival (bounded even when
    /// NJT gives no arrival), so the board follows the whole journey.
    public static func rideView(_ trip: Trip, now: Date, alerts: Bool, changes: [String: TrackChange]) -> TripView? {
        let view = deriveTripView(trip, changes: changes, alerts: alerts)
        let keepUntil: Date
        if let arrival = view.expectedArrival {
            keepUntil = arrival.addingTimeInterval(rideArrivalGrace)
        } else {
            keepUntil = view.expectedDeparture.addingTimeInterval(rideNoArrivalTTL)
        }
        return now > keepUntil ? nil : view
    }

    /// The featured train as last seen, for departure announcements.
    public struct HeroSnapshot: Equatable, Sendable {
        public var key: String
        public var label: String
        public var effectiveDeparture: Date

        public init(key: String, label: String, effectiveDeparture: Date) {
            self.key = key
            self.label = label
            self.effectiveDeparture = effectiveDeparture
        }
    }

    /// Decide whether the previous featured train should be announced as
    /// departed. Only fires when its expected departure has actually passed AND
    /// it has left the upcoming list, so a flaky feed never produces a false
    /// "departed".
    public static func detectDeparture(_ previous: HeroSnapshot?, currentKeys: [String], now: Date) -> String? {
        guard let previous else { return nil }
        if currentKeys.contains(previous.key) { return nil }
        if previous.effectiveDeparture > now { return nil }
        return previous.label
    }
}
