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

/// What a widget shows at one moment.
public struct WidgetSnapshot: Equatable, Sendable {
    public var date: Date
    public var commuteMode: CommuteMode
    public var from: Station
    public var to: Station
    public var next: WidgetTrain?
    public var later: [WidgetTrain]
    public var isSample: Bool
    public var generatedAt: Date
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
            generatedAt: payload.generatedAt,
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
