import Foundation

/// Port of lib/stations.ts, the single source of truth for stations: the four
/// the app has always known, plus every NJ Transit rail station a rider can
/// call home (`Stations.catalog`). The NJT client and the UI both read from it.
public struct Station: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Used for the departure board query.
    public var name: String
    /// Used for the trip planner query (usually `name`, sometimes with " Station").
    public var plannerName: String
    public var shortLabel: String
    public var code: String?
    /// NJ Transit's codes for the lines through the station, as departure
    /// boards give them ("MOBO" is the Montclair-Boonton Line).
    public var lines: [String]

    public init(id: String, name: String, plannerName: String, shortLabel: String, code: String? = nil, lines: [String] = []) {
        self.id = id
        self.name = name
        self.plannerName = plannerName
        self.shortLabel = shortLabel
        self.code = code
        self.lines = lines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        plannerName = try container.decode(String.self, forKey: .plannerName)
        shortLabel = try container.decode(String.self, forKey: .shortLabel)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
    }

    /// What the stop matcher compares NJT stop names against.
    public var ref: StationRef { StationRef(name: name, shortLabel: shortLabel) }

    /// The travel alert groups for its lines, as `getRailAlertsAdvisories`
    /// names them: for the Montclair-Boonton Line, BNTN and BNTNM (its
    /// Midtown Direct trains, the Montclair Line).
    public var alertLines: [String] {
        var groups: [String] = []
        for line in lines {
            for group in Self.alertGroups[line] ?? [] where !groups.contains(group) {
                groups.append(group)
            }
        }
        return groups
    }

    /// Its lines by name, for the station picker.
    public var lineTitles: [String] { lines.compactMap { Self.titles[$0] } }

    static let alertGroups: [String: [String]] = [
        "MOBO": ["BNTN", "BNTNM"], "M&E": ["MNE", "MNEG"], "NEC": ["NEC"], "NJCL": ["NJCL", "NJCLL"],
        "RARV": ["RARV"], "MAIN": ["MNBN", "MNBNP"], "BERG": ["MNBN", "MNBNP"], "PASC": ["PASC"],
        "ACRL": ["ATLC"], "PRIN": ["PRIN"],
    ]

    static let titles: [String: String] = [
        "MOBO": "Montclair-Boonton", "M&E": "Morris & Essex", "NEC": "Northeast Corridor",
        "NJCL": "North Jersey Coast", "RARV": "Raritan Valley", "MAIN": "Main", "BERG": "Bergen County",
        "PASC": "Pascack Valley", "ACRL": "Atlantic City", "PRIN": "Princeton Branch",
    ]
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
        shortLabel: "Watchung Ave",
        lines: ["MOBO"]
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
        shortLabel: "Bay Street",
        lines: ["MOBO"]
    )
    public static let penn = Station(
        id: "penn",
        name: "New York Penn Station",
        plannerName: "New York Penn Station",
        shortLabel: "Penn Station NY",
        code: "NYP"
    )

    /// Every station by id: the catalog, with the four the app has always
    /// known under their own names ("Hoboken Terminal" for Hoboken's board).
    public static let all: [String: Station] = {
        var map: [String: Station] = [:]
        for station in catalog { map[station.id] = station }
        for station in [watchung, hoboken, bayStreet, penn] {
            var known = station
            if known.lines.isEmpty { known.lines = map[station.id]?.lines ?? [] }
            map[station.id] = known
        }
        return map
    }()

    public static func station(_ id: String) -> Station? { all[id] }

    /// The stations a rider can choose as home, by name: any but the destinations.
    public static let homeChoices: [Station] = all.values
        .filter { !UserConfig.destinationIds.contains($0.id) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// Port of `USER_CONFIG`.
public enum UserConfig {
    /// Watchung Avenue: home unless the rider picks another station in Settings.
    public static let defaultHomeId = "watchung"
    /// The rider's home station (see `HomeStation`).
    public static var homeId: String { HomeStation.current }
    public static let destinationIds = ["hoboken", "penn"]
    /// NJ Transit's codes for the lines through home, whose travel alerts the
    /// board shows: for Watchung Avenue the Montclair-Boonton Line (Hoboken
    /// trains) and the Montclair Line (Midtown Direct trains to New York).
    public static var alertLines: [String] { home.alertLines }
    /// Nearest stations to fall back on when home has no service, closest first.
    /// The Montclair Branch runs no weekend trains north of Bay Street, so on a
    /// Saturday or Sunday Watchung Avenue is dead while Bay Street is not.
    /// Other homes have none.
    public static var fallbackOriginIds: [String] { homeId == defaultHomeId ? ["baystreet"] : [] }

    public static var home: Station { Stations.station(homeId) ?? Stations.watchung }
}

/// The rider's home station, kept in the App Group so the widgets use it too.
/// Watchung Avenue unless chosen otherwise in Settings; a stored id the catalog
/// doesn't know, or a destination, falls back to it.
public enum HomeStation {
    static let key = "glass-rail.homeStationId"
    static let defaults = SharedStore(appGroup: SharedStore.appGroup()).defaults

    /// For tests: a home that wins over the stored one.
    public static var override: String?

    public static var current: String {
        valid(override ?? defaults.string(forKey: key))
    }

    /// Store a new home; choosing Watchung Avenue clears the setting.
    public static func set(_ id: String) {
        let chosen = valid(id)
        if chosen == UserConfig.defaultHomeId {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(chosen, forKey: key)
        }
    }

    static func valid(_ id: String?) -> String {
        guard let id, Stations.station(id) != nil, !UserConfig.destinationIds.contains(id) else {
            return UserConfig.defaultHomeId
        }
        return id
    }
}
