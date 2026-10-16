import Foundation

/// Port of lib/journey.ts: where the train is, and which stops matter.
public struct Connection: Equatable, Sendable {
    /// Where the rider changes trains.
    public var station: String
    /// The train that collects them there, when the feed named it.
    public var trainId: String?
    /// Live departure from that station, read off the connecting train's run.
    public var departure: Date?
    /// When the rider's own train gets there, read off its run. NJ Transit
    /// lists one time a stop, when the train leaves it, so this can run a
    /// minute late: a warning comes early, never late.
    public var arrival: Date?
    /// The connecting train has already left the station.
    public var departed: Bool
    /// The rider's train has already left the station: the change is behind them.
    public var arrived: Bool
    /// The train to wait for instead, when this one is missed (see
    /// `Journey.nextConnection`).
    public var next: Onward?

    public init(
        station: String,
        trainId: String?,
        departure: Date?,
        arrival: Date? = nil,
        departed: Bool = false,
        arrived: Bool = false,
        next: Onward? = nil
    ) {
        self.station = station
        self.trainId = trainId
        self.departure = departure
        self.arrival = arrival
        self.departed = departed
        self.arrived = arrived
        self.next = next
    }

    /// A later train on from the station, read off its own run.
    public struct Onward: Equatable, Sendable {
        public var trainId: String
        /// When it leaves the station.
        public var departure: Date
        /// When it gets to the rider's destination.
        public var arrival: Date?

        public init(trainId: String, departure: Date, arrival: Date?) {
            self.trainId = trainId
            self.departure = departure
            self.arrival = arrival
        }

        /// Gets the rider in sooner: the earlier arrival, then the earlier
        /// departure, then the lower number, so the pick never depends on
        /// the order the runs come in.
        func beats(_ other: Onward) -> Bool {
            let mine = arrival ?? .distantFuture
            let theirs = other.arrival ?? .distantFuture
            if mine != theirs { return mine < theirs }
            if departure != other.departure { return departure < other.departure }
            return trainId < other.trainId
        }
    }

    /// Less time than this to change trains is a tight connection.
    public static let tightUnder: TimeInterval = 2 * 60

    public enum Risk: Equatable, Sendable {
        /// Due in with this many whole minutes to change (0 or 1).
        case tight(minutes: Int)
        /// Due in after the connecting train leaves, or it has already left.
        case missed
    }

    /// Whether the change is at risk, by both trains' live runs:
    /// - missed: the connecting train is due out of the station before the
    ///   rider's train is. That holds once both have been through (their
    ///   final times), so a rider who missed it is still told so, and of the
    ///   train to wait for. With no time for the connecting train, missed
    ///   only when it has left before the rider's train got there.
    /// - tight: under `tightUnder` between the two, while neither has left.
    /// Nothing without the rider's train's run, and nothing once either train
    /// has left with the times not saying missed: the rider made it or not.
    public var risk: Risk? {
        guard let arrival else { return nil }
        guard let departure else { return departed && !arrived ? .missed : nil }
        let slack = departure.timeIntervalSince(arrival)
        if slack < 0 { return .missed }
        if departed || arrived { return nil }
        if slack < Self.tightUnder { return .tight(minutes: Int(slack / 60)) }
        return nil
    }
}

public enum Journey {
    private static let ignoredTokens: Set<String> = ["station", "terminal", "street", "st"]

    /// NJT stop names and our station config differ in suffixes and word order
    /// ("Hoboken" vs "Hoboken Terminal", "Penn Station New York" vs
    /// "New York Penn Station"). Compare on sorted significant tokens.
    static func normTokens(_ value: String) -> [String] {
        let lowered = value.lowercased()
        let spaced = RX.replaceAll("[^a-z0-9 ]+", in: lowered, with: " ")
        return spaced
            .split(whereSeparator: { $0 == " " || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty && !ignoredTokens.contains($0) }
            .sorted()
    }

    public static func stopMatchesStation(_ stopName: String, _ station: StationRef) -> Bool {
        let stop = normTokens(stopName).joined(separator: " ")
        if stop.isEmpty { return false }
        for candidate in [station.name, station.shortLabel] {
            let ours = normTokens(candidate).joined(separator: " ")
            if ours.isEmpty { continue }
            if stop == ours || stop.contains(ours) || ours.contains(stop) {
                return true
            }
        }
        return false
    }

    public static func mostRecentDeparted(_ stops: [TrainStop]) -> TrainStop? {
        stops.last(where: { $0.departed })
    }

    public static func nextStop(_ stops: [TrainStop]) -> TrainStop? {
        stops.first(where: { !$0.departed })
    }

    /// Index of the next stop, for highlighting it in the stops sheet.
    public static func nextStopIndex(_ stops: [TrainStop]) -> Int? {
        stops.firstIndex(where: { !$0.departed })
    }

    public static func upcomingStops(_ stops: [TrainStop]) -> [TrainStop] {
        stops.filter { !$0.departed }
    }

    /// Where the train is along the rider's origin to destination segment, 0...1.
    /// Driven by NJT's per-stop departed flags, refined by time interpolation
    /// between the last departed stop and the next one. nil when either end of
    /// the segment is not on this run (caller falls back to the schedule).
    public static func journeyProgress(_ stops: [TrainStop], origin: StationRef, dest: StationRef, now: Date) -> Double? {
        guard let oi = stops.firstIndex(where: { stopMatchesStation($0.name, origin) }) else { return nil }
        guard let di = stops.indices.first(where: { $0 > oi && stopMatchesStation(stops[$0].name, dest) }) else {
            return nil
        }

        if !stops[oi].departed { return 0 }
        if stops[di].departed { return 1 }

        var lastDeparted = oi
        for index in oi..<di where stops[index].departed {
            lastDeparted = index
        }
        let next = lastDeparted + 1

        guard let tLast = stops[lastDeparted].time?.epochMs,
              let tNext = stops[next].time?.epochMs,
              let tOrigin = stops[oi].time?.epochMs,
              let tDest = stops[di].time?.epochMs,
              tDest > tOrigin else {
            // No usable times: place the train between stops by index.
            return clamp01((Double(lastDeparted) + 0.5 - Double(oi)) / Double(di - oi))
        }

        let seg = tNext > tLast ? clamp01((now.epochMs - tLast) / (tNext - tLast)) : 0.5
        let tCurrent = tLast + seg * (tNext - tLast)
        return clamp01((tCurrent - tOrigin) / (tDest - tOrigin))
    }

    /// Fallback when no stop list is available: linear between the trip's times.
    public static func scheduleProgress(departure: Date, arrival: Date?, now: Date) -> Double {
        if now <= departure { return 0 }
        guard let arrival, arrival > departure else { return 0 }
        return clamp01(now.timeIntervalSince(departure) / arrival.timeIntervalSince(departure))
    }

    /// The connections in a transfer itinerary. The rider's own train only
    /// covers the first leg, so "when does the connecting train pick me up?"
    /// can only be answered from the connecting train's stop list, and "do I
    /// make it?" from the train that brings them in as well.
    public static func tripConnections(_ trip: Trip, runs: Runs) -> [Connection] {
        let legIds = trip.legTrainIds ?? []
        return trip.transferAt.enumerated().map { index, station in
            let trainId: String? = index + 1 < legIds.count ? legIds[index + 1] : nil
            // The train that brings the rider in: the leg before, or their
            // own train for the first change.
            let inboundId: String? = index < legIds.count ? legIds[index] : (index == 0 ? trip.trainId : nil)
            let ref = StationRef(name: station, shortLabel: station)
            let onward = trainId.flatMap { runs[$0] }?.first(where: { stopMatchesStation($0.name, ref) })
            let inbound = inboundId.flatMap { runs[$0] }?.first(where: { stopMatchesStation($0.name, ref) })
            return Connection(
                station: station,
                trainId: trainId,
                departure: onward?.time,
                arrival: inbound?.time,
                departed: onward?.departed ?? false,
                arrived: inbound?.departed ?? false
            )
        }
    }

    /// The train to wait for at a missed connection: of the stop lists on
    /// hand, the one that gets the rider to `dest` soonest, leaving the
    /// station at least `Connection.tightUnder` after their train gets in and
    /// calling at `dest` later in its run. Before the rider's train gets
    /// there, a train that has already left can't be it; after, it may be the
    /// one they are on. A time more than three hours on belongs to another
    /// day's train of that number. nil when nothing on hand goes there, or
    /// the connection isn't missed.
    public static func nextConnection(after connection: Connection, toward dest: StationRef, runs: Runs) -> Connection.Onward? {
        guard connection.risk == .missed, let arrival = connection.arrival else { return nil }
        let station = StationRef(name: connection.station, shortLabel: connection.station)
        func calls(_ stop: TrainStop, at ref: StationRef) -> Bool {
            stopMatchesStation(stop.name, ref) && stop.status?.lowercased().contains("cancel") != true
        }
        var best: Connection.Onward?
        for (trainId, stops) in runs where trainId != connection.trainId {
            guard let at = stops.firstIndex(where: { calls($0, at: station) }),
                  connection.arrived || !stops[at].departed,
                  let leaves = stops[at].time,
                  leaves.timeIntervalSince(arrival) >= Connection.tightUnder,
                  leaves.timeIntervalSince(arrival) <= 3 * 3600,
                  let there = stops[(at + 1)...].first(where: { calls($0, at: dest) })
            else { continue }
            let candidate = Connection.Onward(trainId: trainId, departure: leaves, arrival: there.time)
            if best.map(candidate.beats) ?? true { best = candidate }
        }
        return best
    }

    /// The featured trip: the pinned one while it is still upcoming, else the first.
    public static func pickHero(_ views: [TripView], pinnedKey: String?) -> TripView? {
        if let pinnedKey, let pinned = views.first(where: { $0.key == pinnedKey }) {
            return pinned
        }
        return views.first
    }

    static func clamp01(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        return max(0, min(1, value))
    }
}
