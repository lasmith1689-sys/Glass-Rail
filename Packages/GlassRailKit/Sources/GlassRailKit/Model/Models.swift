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
        statusNote: String? = nil
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

    public init(generatedAt: Date, source: PayloadSource, trips: [Trip]) {
        self.generatedAt = generatedAt
        self.source = source
        self.trips = trips
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
