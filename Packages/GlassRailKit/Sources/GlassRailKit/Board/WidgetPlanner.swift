import Foundation

/// One train as a widget shows it.
public struct WidgetTrain: Equatable, Sendable, Codable {
    public var trainId: String?
    /// Timetable departure.
    public var scheduledDeparture: Date
    /// True pickup time (live stop time when known), which the countdown uses.
    public var departure: Date
    public var arrival: Date?
    public var track: String?
    public var delayed: Bool
    public var delayMinutes: Int?
    public var cancelled: Bool
    public var transferCount: Int

    public init(view: TripView) {
        trainId = view.trip.trainId
        scheduledDeparture = view.trip.departure
        departure = view.expectedDeparture
        arrival = view.expectedArrival
        track = view.trip.track
        delayed = view.delayed
        delayMinutes = view.delayMinutes
        cancelled = view.cancelled
        transferCount = view.trip.transferCount
    }
}

extension WidgetTrain {
    /// The inline Lock Screen line. It shares a narrow row with the date, so
    /// it says one thing after the time: the track, or what is wrong.
    /// "2:36 PM · Tk 2", "2:42 PM · +6m", "Cancelled 2:36 PM".
    public var inlineSummary: String {
        let time = Format.time(departure)
        if cancelled { return "Cancelled \(time)" }
        if delayed { return "\(time) · \(delayMinutes.map { "+\($0)m" } ?? "late")" }
        guard let track, !track.isEmpty else { return time }
        return "\(time) · Tk \(track)"
    }
}

/// What a widget shows at one moment.
public struct WidgetSnapshot: Equatable, Sendable {
    public var date: Date
    public var commuteMode: CommuteMode
    public var from: Station
    public var to: Station
    public var next: WidgetTrain?
    public var later: [WidgetTrain]
    public var isSample: Bool
    /// When this direction's trips were fetched, which is earlier than the
    /// payload itself when they were carried over from a previous refresh;
    /// nil when NJ Transit never answered for this direction.
    public var updatedAt: Date?
    /// NJ Transit never answered for this direction, so an empty list means
    /// "unknown", not "no more trains".
    public var unanswered: Bool { !isSample && updatedAt == nil }
    /// The same LIVE / STALE / SAMPLE call the app makes for this direction.
    public var feedMode: FeedMode
    public var noService: Bool
    /// Nearest station with service when the rider's own has none.
    public var alternateFrom: Station?
    public var alternateNext: WidgetTrain?
}

/// Builds widget timelines from the same board logic the app uses, so the
/// widget's "next train" always matches the app's (by clock direction; the
/// widget ignores pins and manual flips).
public enum WidgetPlanner {
    /// Timeline entries reach this far ahead at most.
    public static let horizon: TimeInterval = 4 * 3600
    public static let maxEntries = 12

    /// `modeOverride` is only for previews; widgets follow the clock.
    public static func snapshot(payload: Payload, runs: Runs, destinationId: String, at date: Date, modeOverride: ModeOverride? = nil) -> WidgetSnapshot {
        let state = BoardEngine.compute(BoardInputs(payload: payload, runs: runs, now: date, destinationId: destinationId, modeOverride: modeOverride))
        return WidgetSnapshot(
            date: date,
            commuteMode: state.commuteMode,
            from: state.from,
            to: state.to,
            next: state.hero.map(WidgetTrain.init(view:)),
            later: state.later.prefix(3).map(WidgetTrain.init(view:)),
            isSample: payload.source.kind == .sample,
            updatedAt: state.dataUpdatedAt,
            feedMode: state.feedMode,
            noService: state.noService,
            alternateFrom: state.alternate?.from,
            alternateNext: state.alternate?.views.first.map(WidgetTrain.init(view:))
        )
    }

    /// Moments at which the widget's content changes: now, each time the
    /// featured train drops off the board (a minute after it leaves, like the
    /// app), and the 2 PM / midnight direction boundary.
    public static func entryDates(payload: Payload, runs: Runs, destinationId: String, now: Date) -> [Date] {
        let limit = now.addingTimeInterval(horizon)
        var dates: [Date] = [now]
        var cursor = now
        while dates.count < maxEntries {
            let state = BoardEngine.compute(BoardInputs(payload: payload, runs: runs, now: cursor, destinationId: destinationId))
            guard let hero = state.hero else { break }
            let gone = max(hero.expectedDeparture.addingTimeInterval(Status.departureGrace + 1), cursor.addingTimeInterval(60))
            if gone > limit { break }
            dates.append(gone)
            cursor = gone
        }
        let boundary = Direction.nextBoundary(after: now)
        if boundary < limit { dates.append(boundary) }
        var seen = Set<Date>()
        return dates.sorted().filter { seen.insert($0).inserted }.prefix(maxEntries).map { $0 }
    }

    public static func timeline(payload: Payload, runs: Runs, destinationId: String, now: Date) -> [WidgetSnapshot] {
        entryDates(payload: payload, runs: runs, destinationId: destinationId, now: now)
            .map { snapshot(payload: payload, runs: runs, destinationId: destinationId, at: $0) }
    }

    /// When to ask for a fresh timeline: 5 minutes when a train is leaving
    /// soon (delays and tracks change fast then), otherwise 10.
    public static func reloadDate(now: Date, first: WidgetSnapshot?) -> Date {
        if let departure = first?.next?.departure, departure.timeIntervalSince(now) < 20 * 60 {
            return now.addingTimeInterval(5 * 60)
        }
        return now.addingTimeInterval(10 * 60)
    }

    /// The app's saved board is reused as-is when it is at most this old, so a
    /// widget reload right after the app refreshed costs no network at all.
    public static let reuseSavedDataFor: TimeInterval = 5 * 60

    /// Planner lookups per direction when the widget fetches for itself: now
    /// and 75 minutes out (the app makes four). That covers the next two to
    /// three hours both ways, well past the next reload, and the other
    /// direction's trains for the 2 PM switch.
    public static let plannerOffsetsMinutes = [0, 75]

    /// Whether the app's saved board is fresh enough to use without fetching.
    /// Only live data counts; a timestamp far in the future (a clock change)
    /// doesn't make data fresh. With `pairKey`, it is that direction's own
    /// data that must be fresh: a direction the app carried over from an
    /// earlier refresh is as old as its trips, not as the payload.
    public static func canReuse(_ payload: Payload, now: Date, pairKey: String? = nil) -> Bool {
        guard payload.source.kind == .live else { return false }
        let updated: Date? = pairKey.map { payload.updatedAt(forPair: $0) } ?? payload.generatedAt
        guard let updated else { return false }
        let age = now.timeIntervalSince(updated)
        return age <= reuseSavedDataFor && age >= -reuseSavedDataFor
    }

    /// The direction a widget shows at `now` (by clock, no flips): the one its
    /// own fetch must not fail for.
    public static func currentPair(destinationId: String, now: Date) -> ODPair {
        BoardEngine.shownPair(now: now, destinationId: destinationId, modeOverride: nil)
    }

    /// The two directions for the chosen terminal, which is all a widget needs.
    public static func pairs(destinationId: String) -> [ODPair] {
        [
            ODPair(fromId: UserConfig.homeId, toId: destinationId),
            ODPair(fromId: destinationId, toId: UserConfig.homeId),
        ]
    }

    /// Trains worth a stop-list lookup for the widget: what the app would load
    /// for the current direction, then the first trains the other way.
    public static func trainsNeedingStops(payload: Payload, destinationId: String, now: Date) -> [String] {
        let state = BoardEngine.compute(BoardInputs(payload: payload, now: now, destinationId: destinationId))
        var ids = state.trackedTrainIds
        let other = BoardEngine.compute(BoardInputs(
            payload: payload,
            now: now,
            destinationId: destinationId,
            modeOverride: ModeOverride(mode: state.commuteMode.flipped, at: now)
        ))
        for view in other.direction.prefix(2) {
            if let id = view.trip.trainId, !ids.contains(id) { ids.append(id) }
        }
        return Array(ids.prefix(NJTQueries.maxStopListTrains))
    }
}
