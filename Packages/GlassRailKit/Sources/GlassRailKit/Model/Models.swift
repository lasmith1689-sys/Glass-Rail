import Foundation

/// Port of lib/types.ts. Times are `Date`s rather than ISO strings; they are
/// written as ISO strings whenever they are persisted (see `GlassRailJSON`).
public enum TripStatus: String, Codable, Sendable, Hashable {
    case onTime = "on-time"
    case delayed
    case cancelled
}

public struct TrainStop: Codable, Equatable, Hashable, Sendable {
    public var name: String
    /// nil when NJT's time string could not be parsed.
    public var time: Date?
    public var departed: Bool
    public var status: String?
    /// Boarding restriction from NJT, e.g. "Discharge Only".
    public var note: String?

    public init(name: String, time: Date?, departed: Bool, status: String?, note: String?) {
        self.name = name
        self.time = time
        self.departed = departed
        self.status = status
        self.note = note
    }
}

public struct Trip: Codable, Equatable, Hashable, Sendable {
    public var fromId: String
    public var toId: String
    public var trainId: String?
    public var departure: Date
    public var arrival: Date?
    public var track: String?
    public var transferCount: Int
    public var transferAt: [String]
    /// Train number of each rail leg in order, so a transfer trip can report
    /// which train collects the rider at the connection. Optional: fixtures
    /// and older stored pins predate it.
    public var legTrainIds: [String]?
    public var note: String?
    /// Structured status from the origin departure board; nil = board had no info.
    public var status: TripStatus?
    /// NJT's own message when the board reports an anomaly (delay/cancel text).
    public var statusNote: String?
    /// When the origin station's departure board last listed this train,
    /// which means it had not left yet. nil when the board didn't list it.
    public var listedAt: Date?
    /// The board's countdown at `listedAt`: "in 7 Min" is 7, "All Aboard" 0.
    /// It counts down to the real departure, so it shows a late train.
    public var countdownMinutes: Int?
    /// Where the train ends when that isn't this trip's destination, from the
    /// home station's board: "Hoboken" for a New York train sent to Hoboken.
    public var terminus: String?

    public init(
        fromId: String,
        toId: String,
        trainId: String?,
        departure: Date,
        arrival: Date?,
        track: String? = nil,
        transferCount: Int = 0,
        transferAt: [String] = [],
        legTrainIds: [String]? = nil,
        note: String? = nil,
        status: TripStatus? = nil,
        statusNote: String? = nil,
        listedAt: Date? = nil,
        countdownMinutes: Int? = nil,
        terminus: String? = nil
    ) {
        self.fromId = fromId
        self.toId = toId
        self.trainId = trainId
        self.departure = departure
        self.arrival = arrival
        self.track = track
        self.transferCount = transferCount
        self.transferAt = transferAt
        self.legTrainIds = legTrainIds
        self.note = note
        self.status = status
        self.statusNote = statusNote
        self.listedAt = listedAt
        self.countdownMinutes = countdownMinutes
        self.terminus = terminus
    }
}

public enum SourceKind: String, Codable, Sendable, Hashable {
    case live
    case sample
}

public struct PayloadSource: Codable, Equatable, Sendable, Hashable {
    public var kind: SourceKind
    public var detail: String

    public init(kind: SourceKind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

public struct Payload: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var source: PayloadSource
    public var trips: [Trip]
    /// Directions (`from|to`, as looked up) whose lookup failed in the refresh
    /// that built this payload, so their trips were carried over from an
    /// earlier one: when those trips were fetched. Every other direction is
    /// as of `generatedAt`. nil in older saved payloads.
    public var carriedOver: [String: Date]?
    /// Directions whose lookup failed with nothing to carry over. Their trips
    /// are unknown, which is not the same as none.
    public var unanswered: [String]?
    /// NJ Transit's travel alerts for the lines through home (see
    /// `UserConfig.alertLines`); nil when they weren't fetched.
    public var alerts: [String]?

    public init(
        generatedAt: Date,
        source: PayloadSource,
        trips: [Trip],
        carriedOver: [String: Date]? = nil,
        unanswered: [String]? = nil,
        alerts: [String]? = nil
    ) {
        self.generatedAt = generatedAt
        self.source = source
        self.trips = trips
        self.carriedOver = carriedOver
        self.unanswered = unanswered
        self.alerts = alerts
    }

    /// When one direction's trips were fetched: `generatedAt`, or earlier for
    /// a direction carried over from a previous refresh. nil when its lookup
    /// failed with nothing to carry over.
    public func updatedAt(forPair key: String) -> Date? {
        if unanswered?.contains(key) == true { return nil }
        return carriedOver?[key] ?? generatedAt
    }

    /// True when this refresh did not get its own answer for the direction.
    public func isCarriedOver(pair key: String) -> Bool {
        carriedOver?[key] != nil || unanswered?.contains(key) == true
    }
}

/// Live stop lists keyed by train id, as v4's /api/stops returned them.
public typealias Runs = [String: [TrainStop]]

/// JSON coding that writes dates like JavaScript's `toISOString()`.
public enum GlassRailJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISOTime.string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = ISOTime.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }
}
