import Foundation

/// Port of lib/journey.ts: where the train is, and which stops matter.
public struct Connection: Equatable, Sendable {
    /// Where the rider changes trains.
    public var station: String
    /// The train that collects them there, when the feed named it.
    public var trainId: String?
    /// Live departure from that station, read off the connecting train's run.
    public var departure: Date?

    public init(station: String, trainId: String?, departure: Date?) {
        self.station = station
        self.trainId = trainId
        self.departure = departure
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
    /// can only be answered from the connecting train's stop list.
    public static func tripConnections(_ trip: Trip, runs: Runs) -> [Connection] {
        trip.transferAt.enumerated().map { index, station in
            let legIds = trip.legTrainIds ?? []
            let trainId: String? = index + 1 < legIds.count ? legIds[index + 1] : nil
            let stops = trainId.flatMap { runs[$0] }
            let ref = StationRef(name: station, shortLabel: station)
            let match = stops?.first(where: { stopMatchesStation($0.name, ref) })
            return Connection(station: station, trainId: trainId, departure: match?.time)
        }
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
