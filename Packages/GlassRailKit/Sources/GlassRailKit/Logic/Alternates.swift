import Foundation

/// An origin/destination lookup.
public struct ODPair: Equatable, Hashable, Sendable {
    public var fromId: String
    public var toId: String

    public init(fromId: String, toId: String) {
        self.fromId = fromId
        self.toId = toId
    }

    /// Key for the empty-direction set: `from|to`.
    public var key: String { "\(fromId)|\(toId)" }
}

/// Port of lib/alternates.ts. Some stations have no service at certain times
/// (the Montclair Branch runs no weekend trains north of Bay Street). When the
/// rider's own station comes back empty, these helpers work out which nearby
/// station to offer instead.
public enum Alternates {
    /// The journeys worth offering when `homeId` has no service on this route.
    public static func alternateRoutes(fromId: String, toId: String, homeId: String, fallbackIds: [String]) -> [ODPair] {
        var routes: [ODPair] = []
        for id in fallbackIds {
            // A fallback that is already the other end of the trip is no help.
            if id == fromId || id == toId { continue }
            if fromId == homeId {
                routes.append(ODPair(fromId: id, toId: toId))
            } else if toId == homeId {
                routes.append(ODPair(fromId: fromId, toId: id))
            }
        }
        return routes
    }

    public static func pairKey(_ pair: ODPair) -> String { pair.key }

    /// Extra lookups to make, given which of the primary pairs came back with
    /// nothing. Only empty directions are retried, so a normal weekday costs no
    /// additional requests.
    public static func substitutePairs(_ pairs: [ODPair], emptyPairKeys: Set<String>, homeId: String, fallbackIds: [String]) -> [ODPair] {
        var already = Set(pairs.map(\.key))
        var out: [ODPair] = []
        for pair in pairs where emptyPairKeys.contains(pair.key) {
            for route in alternateRoutes(fromId: pair.fromId, toId: pair.toId, homeId: homeId, fallbackIds: fallbackIds) {
                if already.contains(route.key) { continue }
                already.insert(route.key)
                out.append(route)
            }
        }
        return out
    }

    /// Both directions between home and every destination (v4's `defaultPairs`).
    public static func defaultPairs() -> [ODPair] {
        var pairs: [ODPair] = []
        for dest in UserConfig.destinationIds {
            pairs.append(ODPair(fromId: UserConfig.homeId, toId: dest))
            pairs.append(ODPair(fromId: dest, toId: UserConfig.homeId))
        }
        return pairs
    }
}
