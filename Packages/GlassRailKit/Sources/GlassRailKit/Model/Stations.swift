import Foundation

/// Port of lib/stations.ts, the single source of truth for stations.
/// To add a station, add an entry to `Stations.all`; the NJT client and the UI
/// both read from it.
public struct Station: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Used for the departure board query.
    public var name: String
    /// Used for the trip planner query (usually `name`, sometimes with " Station").
    public var plannerName: String
    public var shortLabel: String
    public var code: String?

    public init(id: String, name: String, plannerName: String, shortLabel: String, code: String? = nil) {
        self.id = id
        self.name = name
        self.plannerName = plannerName
        self.shortLabel = shortLabel
        self.code = code
    }

    /// What the stop matcher compares NJT stop names against.
    public var ref: StationRef { StationRef(name: name, shortLabel: shortLabel) }
}

/// The two names a station is known by, for matching against NJT stop names.
public struct StationRef: Equatable, Hashable, Sendable {
    public var name: String
    public var shortLabel: String

    public init(name: String, shortLabel: String) {
        self.name = name
        self.shortLabel = shortLabel
    }
}

public enum Stations {
    public static let watchung = Station(
        id: "watchung",
        name: "Watchung Avenue",
        plannerName: "Watchung Avenue Station",
        shortLabel: "Watchung Ave"
    )
    public static let hoboken = Station(
        id: "hoboken",
        name: "Hoboken Terminal",
        plannerName: "Hoboken Terminal",
        shortLabel: "Hoboken",
        code: "HOB"
    )
    public static let bayStreet = Station(
        id: "baystreet",
        name: "Bay Street",
        plannerName: "Bay Street Station",
        shortLabel: "Bay Street"
    )
    public static let penn = Station(
        id: "penn",
        name: "New York Penn Station",
        plannerName: "New York Penn Station",
        shortLabel: "Penn Station NY",
        code: "NYP"
    )

    public static let all: [String: Station] = [
        watchung.id: watchung,
        hoboken.id: hoboken,
        bayStreet.id: bayStreet,
        penn.id: penn,
    ]

    public static func station(_ id: String) -> Station? { all[id] }
}

/// Port of `USER_CONFIG`.
public enum UserConfig {
    public static let homeId = "watchung"
    public static let destinationIds = ["hoboken", "penn"]
    /// Nearest stations to fall back on when home has no service, closest first.
    /// The Montclair Branch runs no weekend trains north of Bay Street, so on a
    /// Saturday or Sunday Watchung Avenue is dead while Bay Street is not.
    public static let fallbackOriginIds = ["baystreet"]

    public static var home: Station { Stations.watchung }
}
