import Foundation

/// Port of lib/pin.ts: a tapped "later" train, remembered across launches.
public struct Pin: Codable, Equatable, Hashable, Sendable {
    public var dirKey: String
    public var key: String

    public init(dirKey: String, key: String) {
        self.dirKey = dirKey
        self.key = key
    }

    /// The train number inside a pin key (`from|to|train`).
    public var trainId: String? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count > 2 ? String(parts[2]) : nil
    }
}

/// A restored pin, plus the last known trip for it (may be absent).
public struct RestoredPin: Equatable, Sendable {
    public var dirKey: String
    public var key: String
    public var trip: Trip?

    public var pin: Pin { Pin(dirKey: dirKey, key: key) }
}

public enum PinStore {
    /// How long a pinned train is remembered across launches. Long enough to
    /// cover a delayed ride end to end, short enough that tomorrow's
    /// identically numbered train is never auto-pinned.
    public static let ttl: TimeInterval = 3 * 60 * 60

    /// The pin stores the trip itself, not just its key. NJ Transit's planner
    /// stops returning a departure once it has left, so after a relaunch
    /// mid-ride this copy is the only remaining description of the train.
    public static func serialize(_ pin: Pin, trip: Trip?, now: Date) -> String {
        let object: [String: Any] = [
            "dirKey": pin.dirKey,
            "key": pin.key,
            "at": ISOTime.string(from: now),
            "trip": orNull(trip.map { tripJSONObject($0) }),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public static func parse(_ raw: String?, now: Date) -> RestoredPin? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let saved = parsed as? [String: Any] else {
            return nil
        }
        guard let dirKey = saved["dirKey"] as? String, !dirKey.isEmpty else { return nil }
        guard let key = saved["key"] as? String, !key.isEmpty else { return nil }
        guard let atText = saved["at"] as? String, let at = ISOTime.date(from: atText) else { return nil }
        // Future timestamps (clock skew) are kept: only genuine age expires a pin.
        if now.timeIntervalSince(at) > ttl { return nil }
        return RestoredPin(dirKey: dirKey, key: key, trip: validTrip(saved["trip"], key: key))
    }

    /// A stored trip that is not the pinned train is worse than none at all.
    static func validTrip(_ value: Any?, key: String) -> Trip? {
        guard let object = value as? [String: Any] else { return nil }
        guard let fromId = object["fromId"] as? String, let toId = object["toId"] as? String else { return nil }
        guard let departureText = object["departure"] as? String, !departureText.isEmpty,
              let departure = ISOTime.date(from: departureText) else {
            return nil
        }
        guard let transferAt = object["transferAt"] as? [Any] else { return nil }
        guard let transferCount = object["transferCount"] as? NSNumber, !JSONValue.isBool(transferCount) else { return nil }
        let trip = Trip(
            fromId: fromId,
            toId: toId,
            trainId: object["trainId"] as? String,
            departure: departure,
            arrival: (object["arrival"] as? String).flatMap(ISOTime.date(from:)),
            track: object["track"] as? String,
            transferCount: transferCount.intValue,
            transferAt: transferAt.compactMap { $0 as? String },
            legTrainIds: (object["legTrainIds"] as? [Any])?.compactMap { $0 as? String },
            note: object["note"] as? String,
            status: (object["status"] as? String).flatMap(TripStatus.init(rawValue:)),
            statusNote: object["statusNote"] as? String
        )
        guard Status.tripKey(trip) == key else { return nil }
        return trip
    }

    static func tripJSONObject(_ trip: Trip) -> [String: Any] {
        var object: [String: Any] = [
            "fromId": trip.fromId,
            "toId": trip.toId,
            "trainId": orNull(trip.trainId),
            "departure": ISOTime.string(from: trip.departure),
            "arrival": orNull(trip.arrival.map { ISOTime.string(from: $0) }),
            "track": orNull(trip.track),
            "transferCount": trip.transferCount,
            "transferAt": trip.transferAt,
            "note": orNull(trip.note),
            "status": orNull(trip.status?.rawValue),
            "statusNote": orNull(trip.statusNote),
        ]
        if let legs = trip.legTrainIds { object["legTrainIds"] = legs }
        return object
    }
}

/// `value ?? null` for JSONSerialization.
func orNull(_ value: Any?) -> Any {
    if let value { return value }
    return NSNull()
}

/// Helpers for reading loosely typed JSON the way JavaScript would.
enum JSONValue {
    /// JSON `true`/`false` arrive as NSNumber; tell them apart from 0 and 1.
    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `value === true`
    static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, isBool(number) else { return false }
        return number.boolValue
    }

    /// `String(value ?? "")` for the scalar values a JSON API returns.
    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case is NSNull:
            return nil
        case let text as String:
            return text
        case let number as NSNumber:
            if isBool(number) { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            return nil
        }
    }
}
