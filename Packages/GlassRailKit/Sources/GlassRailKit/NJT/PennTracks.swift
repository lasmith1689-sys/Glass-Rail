import Foundation

/// A call on a New York Penn departure's track before NJ Transit posts it,
/// from Glass Rail's track checker (supabase/README.md). NJ Transit posts a
/// Penn track about nine minutes before departure; the checker's live
/// sources usually know twenty minutes or more before that.
public struct TrackCall: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// The train's set stands on the platform's signalling track circuit.
        case signal
        /// The board shows the coordinate of the platform the train waits at.
        case berth
        /// No live sign yet: how often each track has served this train.
        case history
    }

    public var track: String
    /// How likely the call is: a live source's measured hit rate over the
    /// last 14 days, or the history guess's own probability.
    public var probability: Double
    public var source: Source

    public init(track: String, probability: Double, source: Source) {
        self.track = track
        self.probability = probability
        self.source = source
    }

    /// "98%", never "100%" or "0%": nothing the board hasn't posted is
    /// certain, and a call shown at all is never hopeless.
    public var percentText: String {
        "\(min(99, max(1, Int((probability * 100).rounded()))))%"
    }
}

/// What the checker says about New York Penn's NJ Transit departures.
public struct PennTracks: Equatable, Sendable {
    public struct Departure: Equatable, Sendable {
        public var trainId: String
        public var scheduled: Date
        /// The board's own track, once posted.
        public var track: String?
        public var call: TrackCall?

        public init(trainId: String, scheduled: Date, track: String? = nil, call: TrackCall? = nil) {
            self.trainId = trainId
            self.scheduled = scheduled
            self.track = track
            self.call = call
        }
    }

    /// When the checker last read NJ Transit.
    public var lastPoll: Date?
    public var departures: [Departure]

    public init(lastPoll: Date?, departures: [Departure]) {
        self.lastPoll = lastPoll
        self.departures = departures
    }

    /// A checker that has stopped polling could be calling a track the board
    /// has since posted otherwise, so its calls count for this long.
    public static let freshFor: TimeInterval = 5 * 60
    /// How far the checker's scheduled time may sit from the trip's.
    public static let matchWindow: TimeInterval = 3 * 60

    /// The call for a trip leaving New York Penn: the same train at the same
    /// scheduled time. None once the trip has its posted track: the board's
    /// word always wins.
    public func call(for trip: Trip, now: Date) -> TrackCall? {
        guard trip.fromId == "penn", trip.track == nil, let trainId = trip.trainId,
              let lastPoll, now.timeIntervalSince(lastPoll) <= Self.freshFor else { return nil }
        return departures.first {
            $0.trainId == trainId && abs($0.scheduled.timeIntervalSince(trip.departure)) <= Self.matchWindow
        }?.call
    }

    public enum ParseError: Error {
        case notAnObject
    }

    /// Reads the checker's reply (`penn_board()` through the penn-tracks
    /// function). Departures it can't read are skipped, not fatal.
    public static func parse(_ data: Data) throws -> PennTracks {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        let departures = (root["departures"] as? [[String: Any]] ?? []).compactMap { item -> Departure? in
            guard let trainId = item["trainId"] as? String,
                  let scheduled = (item["scheduled"] as? String).flatMap(ISOTime.date(from:)) else { return nil }
            var call: TrackCall?
            if let prediction = item["prediction"] as? [String: Any],
               let track = prediction["track"] as? String,
               let probability = (prediction["probability"] as? NSNumber)?.doubleValue,
               let source = (prediction["source"] as? String).flatMap(TrackCall.Source.init(rawValue:)) {
                call = TrackCall(track: track, probability: probability, source: source)
            }
            return Departure(trainId: trainId, scheduled: scheduled, track: item["track"] as? String, call: call)
        }
        return PennTracks(
            lastPoll: (root["lastPoll"] as? String).flatMap(ISOTime.date(from:)),
            departures: departures
        )
    }
}

/// Fetches the checker's calls. The function is public and read-only, so
/// the app needs no key for it.
public struct PennTracksClient: Sendable {
    public static let endpoint = URL(string: "https://hhzizoiftyuvqgscyqxh.supabase.co/functions/v1/penn-tracks")!

    public var load: @Sendable () async throws -> Data

    public init(load: @escaping @Sendable () async throws -> Data = PennTracksClient.download) {
        self.load = load
    }

    public func fetch() async throws -> PennTracks {
        try PennTracks.parse(await load())
    }

    public static let download: @Sendable () async throws -> Data = {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
