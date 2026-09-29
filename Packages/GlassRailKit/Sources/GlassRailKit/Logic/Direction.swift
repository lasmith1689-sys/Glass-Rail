import Foundation

/// Port of lib/direction.ts.
public enum CommuteMode: String, Codable, Sendable, Hashable {
    case am
    case pm

    public var flipped: CommuteMode { self == .am ? .pm : .am }
}

/// A manual flip: which way the rider chose, and when they chose it.
/// `at` is optional so an unparseable stored value can be represented and
/// ignored, as v4 ignores an invalid date string.
public struct ModeOverride: Codable, Equatable, Sendable {
    public var mode: CommuteMode
    public var at: Date?

    public init(mode: CommuteMode, at: Date?) {
        self.mode = mode
        self.at = at
    }
}

public enum Direction {
    /// From 2 PM Eastern the likely ride is toward home rather than the city.
    public static let pmBoundaryHour = 14

    /// Direction is derived from the clock, never persisted, so the board can't
    /// show yesterday's commute.
    public static func detectCommuteMode(_ now: Date) -> CommuteMode {
        Eastern.hour(of: now) >= pmBoundaryHour ? .pm : .am
    }

    /// The direction to display. The clock decides, except when the rider has
    /// flipped it themselves, and that flip only holds until the clock next
    /// crosses the 2 PM boundary (or midnight), at which point the automatic
    /// switch takes over again.
    public static func resolveCommuteMode(_ now: Date, override: ModeOverride?) -> CommuteMode {
        let clock = detectCommuteMode(now)
        guard let override, let at = override.at else { return clock }
        return detectCommuteMode(at) == clock ? override.mode : clock
    }

    /// The override still worth applying at `now`, or nil once the clock has
    /// crossed a direction boundary (2 PM or midnight Eastern) since the flip.
    ///
    /// v4 kept the flip in page state only, so a reload always dropped it.
    /// An iOS app can stay in memory for days, and `resolveCommuteMode` alone
    /// would honour a morning flip to PM again the next morning (both
    /// instants are "am"). Lapsing it at the next boundary is what v4's own
    /// comment describes; `resolveCommuteMode` itself is ported unchanged.
    public static func effectiveOverride(_ override: ModeOverride?, now: Date) -> ModeOverride? {
        guard let override, let at = override.at else { return nil }
        if now >= at, nextBoundary(after: at) <= now { return nil }
        return override
    }

    /// The next moment the clock-derived direction changes: 2 PM or midnight
    /// Eastern, whichever comes first. Used to schedule widget reloads.
    public static func nextBoundary(after now: Date) -> Date {
        let (y, m, d) = Eastern.ymd(of: now)
        let hour = Eastern.hour(of: now)
        if hour < pmBoundaryHour, let twoPM = Eastern.date(year: y, month: m, day: d, hour: pmBoundaryHour, minute: 0) {
            return twoPM
        }
        let tomorrow = Eastern.calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let next = Eastern.ymd(of: tomorrow)
        return Eastern.date(year: next.year, month: next.month, day: next.day, hour: 0, minute: 0) ?? now.addingTimeInterval(3600)
    }

    /// Origin and destination for a direction and a chosen city terminal.
    public static func endpoints(mode: CommuteMode, destinationId: String) -> (from: Station, to: Station) {
        let home = UserConfig.home
        let dest = Stations.station(destinationId) ?? Stations.hoboken
        return mode == .am ? (home, dest) : (dest, home)
    }
}
