import Foundation

/// The last known trip for the pinned train. NJ Transit's planner drops a
/// departure as soon as it leaves, so this is what keeps a ride on screen.
public struct RideCache: Equatable, Sendable {
    public var key: String
    public var trip: Trip

    public init(key: String, trip: Trip) {
        self.key = key
        self.trip = trip
    }
}

/// The nearest station with service, shown when the rider's own has none.
public struct Alternate: Equatable, Sendable {
    public var from: Station
    public var to: Station
    public var views: [TripView]
}

/// Everything the board derives on each render in v4's board.tsx.
public struct BoardInputs: Sendable {
    public var payload: Payload
    public var runs: Runs
    public var now: Date
    public var destinationId: String
    public var modeOverride: ModeOverride?
    public var pin: Pin?
    public var rideCache: RideCache?
    /// Track-change alerts accumulated across refreshes (see `TrackState`).
    public var trackChanges: [String: TrackChange]
    public var fetchFailures: Int

    public init(
        payload: Payload,
        runs: Runs = [:],
        now: Date,
        destinationId: String,
        modeOverride: ModeOverride? = nil,
        pin: Pin? = nil,
        rideCache: RideCache? = nil,
        trackChanges: [String: TrackChange] = [:],
        fetchFailures: Int = 0
    ) {
        self.payload = payload
        self.runs = runs
        self.now = now
        self.destinationId = destinationId
        self.modeOverride = modeOverride
        self.pin = pin
        self.rideCache = rideCache
        self.trackChanges = trackChanges
        self.fetchFailures = fetchFailures
    }
}

public struct BoardState: Equatable, Sendable {
    public var commuteMode: CommuteMode
    public var from: Station
    public var to: Station
    /// `from|to`, the scope of a pin.
    public var dirKey: String
    /// LIVE, STALE or SAMPLE for the direction on screen, judged by when its
    /// own trips were fetched (see `dataUpdatedAt`).
    public var feedMode: FeedMode
    /// When the trips this direction shows were fetched: the payload's time,
    /// or earlier when this direction's lookup failed and its trips were
    /// carried over from a previous refresh. nil when its lookup failed with
    /// nothing to carry over (then the board is STALE and never claims "no
    /// trains").
    public var dataUpdatedAt: Date?
    /// NJ Transit never answered for this direction (its lookup failed with
    /// nothing to carry over): its trains are unknown, which is not none.
    public var unanswered: Bool { alerts && dataUpdatedAt == nil }
    /// Operational alerts only ever come from a live payload.
    public var alerts: Bool
    /// Upcoming trips this way, with true pickup/drop-off times, by expected departure.
    public var direction: [TripView]
    /// Which trains to load live stop lists for: the ones on screen.
    public var trackedTrainIds: [String]
    public var activePinKey: String?
    /// The pinned trip, as retained across its own departure.
    public var retainedTrip: Trip?
    /// The featured train: the pinned ride, the pinned upcoming train, or the next one.
    public var hero: TripView?
    public var isPinned: Bool
    /// True while following a pinned train that has already left.
    public var riding: Bool
    /// The pinned train's ride is over: the board stopped following it and it
    /// isn't upcoming either, so the pin has done its job.
    public var pinRideOver: Bool
    public var later: [TripView]
    public var noService: Bool
    public var alternate: Alternate?
    public var heroStops: [TrainStop]?
    public var heroConnections: [Connection]
    public var currentKeys: [String]
    /// The journey dot, 0...1 along origin to destination.
    public var progress: Double
    /// NJ Transit's travel alerts for the lines through home (live data only).
    public var serviceAlerts: [String]
}

extension BoardState {
    /// v4's "On time" chip. It is an operational claim, so like every alert it
    /// needs live data: the bundled sample's trips carry an on-time status too.
    public func showsOnTime(_ view: TripView) -> Bool {
        alerts && !view.delayed && !view.cancelled && view.trackChange == nil && view.trip.status == .onTime
    }
}

/// Port of the derivations in v4's app/board.tsx, as one pure function so the
/// app and the widget show the same train and it can be unit tested.
public enum BoardEngine {
    /// How many trains get live stop lists (hero plus visible later rows).
    public static let stopListTrains = 6
    /// How long the "Train N has departed" notice stays up.
    public static let departedNoticeDuration: TimeInterval = 12

    /// True pickup and drop-off times for one trip from its live stop list.
    public static func applyTiming(_ view: TripView, runs: Runs, origin: Station, dest: Station) -> TripView {
        let stops = view.trip.trainId.flatMap { runs[$0] }
        var timed = Timing.withTiming(
            view,
            Timing.resolveTripTiming(
                stops: stops,
                origin: origin.ref,
                dest: dest.ref,
                scheduledDeparture: view.trip.departure,
                scheduledArrival: view.trip.arrival,
                textDelayMinutes: view.delayMinutes
            )
        )
        // The origin's departure board is the authority on a train it still
        // lists: a live stop time can't make it leave sooner, unless the stop
        // list says it has left. On 5 October 6233's stop list put Hoboken at
        // 10:28 while Hoboken's board still listed it for 10:29, and it
        // vanished while it was boarding.
        if let board = Status.boardDeparture(view.trip), board.time > timed.expectedDeparture,
           stops?.first(where: { Journey.stopMatchesStation($0.name, origin.ref) })?.departed != true {
            timed.expectedDeparture = board.time
        }
        return timed
    }

    /// The trains whose stop lists are worth fetching: the pinned train and
    /// its connections first, then the first few this way (and their
    /// connecting trains), capped at `stopListTrains`.
    public static func trackedTrainIds(base: [TripView], pin: Pin?, rideCache: RideCache?) -> [String] {
        var ids: [String] = []
        func push(_ id: String?) {
            if let id, !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        if let pin { push(pin.trainId) }
        if let rideCache {
            for id in rideCache.trip.legTrainIds ?? [] { push(id) }
        }
        for view in base.prefix(stopListTrains) {
            push(view.trip.trainId)
            if view.trip.transferCount > 0 {
                for id in view.trip.legTrainIds ?? [] { push(id) }
            }
        }
        return Array(ids.prefix(stopListTrains))
    }

    /// The direction the board shows at `now`: the one a refresh must not
    /// fail for (see `NJTClient.fetchLivePayload(required:)`).
    public static func shownPair(now: Date, destinationId: String, modeOverride: ModeOverride?) -> ODPair {
        let commuteMode = Direction.resolveCommuteMode(now, override: modeOverride)
        let (from, to) = Direction.endpoints(mode: commuteMode, destinationId: destinationId)
        return ODPair(fromId: from.id, toId: to.id)
    }

    public static func compute(_ input: BoardInputs) -> BoardState {
        let now = input.now
        let payload = input.payload
        let activeChanges = Status.pruneTrackChanges(input.trackChanges, now: now)
        let commuteMode = Direction.resolveCommuteMode(now, override: input.modeOverride)
        let (from, to) = Direction.endpoints(mode: commuteMode, destinationId: input.destinationId)
        let dirKey = "\(from.id)|\(to.id)"
        // A direction carried over from an earlier refresh ages on its own
        // clock, so it turns STALE even while the other directions are fresh.
        let dataUpdatedAt = payload.updatedAt(forPair: dirKey)
        let feedMode = Status.deriveFeedMode(
            kind: payload.source.kind,
            generatedAt: dataUpdatedAt,
            now: now,
            consecutiveFailures: input.fetchFailures
        )
        let alerts = payload.source.kind == .live
        // Stop-list timing (true pickup/drop-off, the journey dot, connections) is
        // only trusted on live data: sample data must never show a train as late.
        let runs: Runs = alerts ? input.runs : [:]

        // A tapped ("pinned") train takes over the hero card. While upcoming it
        // is picked from the normal list; once it departs it is retained as a
        // ride until shortly after arrival, so the dot can follow the trip.
        let activePinKey = (input.pin?.dirKey == dirKey) ? input.pin?.key : nil

        // Live stop times apply before the departed-train cutoff, so a late
        // train stays while it's still coming. Connections that a later trip
        // beats are left out; the pinned one never is.
        let base = Status.hidingDominatedConnections(
            Status.selectTripViews(
                payload.trips,
                fromId: from.id,
                toId: to.id,
                now: now,
                alerts: alerts,
                changes: activeChanges,
                timing: { markingBrokenConnection(applyTiming($0, runs: runs, origin: from, dest: to), runs: runs) }
            ),
            keeping: activePinKey
        )
        let tracked = trackedTrainIds(base: base, pin: input.pin, rideCache: input.rideCache)
        let direction = base

        var upcomingIndex: Int? = direction.isEmpty ? nil : 0
        if let activePinKey, let pinnedIndex = direction.firstIndex(where: { $0.key == activePinKey }) {
            upcomingIndex = pinnedIndex
        }
        let upcomingHero = upcomingIndex.map { direction[$0] }

        let retainedTrip: Trip? = activePinKey.flatMap { key in
            Status.retainRideTrip(
                cached: input.rideCache?.key == key ? input.rideCache?.trip : nil,
                trips: payload.trips,
                key: key
            )
        }
        var pinnedRide: TripView?
        if let activePinKey, upcomingHero?.key != activePinKey, let retainedTrip,
           let ride = Status.rideView(retainedTrip, now: now, alerts: alerts, changes: activeChanges) {
            pinnedRide = markingBrokenConnection(applyTiming(ride, runs: runs, origin: from, dest: to), runs: runs)
        }
        let hero = pinnedRide ?? upcomingHero
        let isPinned = activePinKey != nil && hero?.key == activePinKey
        let pinRideOver = activePinKey != nil && !isPinned && retainedTrip.map {
            Status.rideView($0, now: now, alerts: alerts, changes: activeChanges) == nil
        } == true
        // Every later train this way: v4 stopped at 10, when its four planner
        // lookups rarely found more.
        var later = direction
        if pinnedRide == nil, let upcomingIndex { later.remove(at: upcomingIndex) }

        // When the rider's own station has no service at all, an empty board
        // is truthful but useless: find the nearest station that has trains.
        // A direction NJ Transit never answered has unknown trains, not none,
        // and old data whose trains have all left says nothing about now: only
        // a fresh answer can say there is no service.
        let noService = direction.isEmpty && payload.source.kind == .live && dataUpdatedAt != nil && feedMode == .live
        var alternate: Alternate?
        if noService {
            for route in Alternates.alternateRoutes(
                fromId: from.id,
                toId: to.id,
                homeId: UserConfig.homeId,
                fallbackIds: UserConfig.fallbackOriginIds
            ) {
                let views = Status.hidingDominatedConnections(
                    Status.selectTripViews(payload.trips, fromId: route.fromId, toId: route.toId, now: now, alerts: alerts, changes: activeChanges)
                )
                if !views.isEmpty, let altFrom = Stations.station(route.fromId), let altTo = Stations.station(route.toId) {
                    alternate = Alternate(from: altFrom, to: altTo, views: Array(views.prefix(3)))
                    break
                }
            }
        }

        let heroRuns = hero.map { runsForTrip($0.trip, runs: runs) } ?? [:]
        let heroStops = hero?.trip.trainId.flatMap { heroRuns[$0] }
        let heroConnections = hero.map { Journey.tripConnections($0.trip, runs: heroRuns) } ?? []

        var progress = 0.0
        if let hero {
            var live: Double?
            if let heroStops, !heroStops.isEmpty {
                live = Journey.journeyProgress(heroStops, origin: from.ref, dest: to.ref, now: now)
            }
            progress = live ?? Journey.scheduleProgress(departure: hero.expectedDeparture, arrival: hero.expectedArrival, now: now)
        }

        return BoardState(
            commuteMode: commuteMode,
            from: from,
            to: to,
            dirKey: dirKey,
            feedMode: feedMode,
            dataUpdatedAt: dataUpdatedAt,
            alerts: alerts,
            direction: direction,
            trackedTrainIds: tracked,
            activePinKey: activePinKey,
            retainedTrip: retainedTrip,
            hero: hero,
            isPinned: isPinned,
            riding: pinnedRide != nil,
            pinRideOver: pinRideOver,
            later: later,
            noService: noService,
            alternate: alternate,
            heroStops: heroStops,
            heroConnections: heroConnections,
            currentKeys: direction.compactMap(\.key),
            progress: progress,
            serviceAlerts: alerts ? (payload.alerts ?? []) : []
        )
    }

    /// `updatedRideCache(_:state:)`, keeping a pinned ride while the board shows
    /// the other direction. v4 forgot it as soon as no pin applied, so flipping
    /// to the other direction mid-ride and back lost the ride (the planner no
    /// longer lists a train that has left), and with it the Live Activity.
    public static func updatedRideCache(_ current: RideCache?, state: BoardState, pin: Pin?) -> RideCache? {
        if state.activePinKey == nil, let pin, current?.key == pin.key { return current }
        return updatedRideCache(current, state: state)
    }

    /// Whether a pin has lapsed. A pin's key is `from|to|train` with no date
    /// and train numbers repeat every day, so a pin kept while the app stays in
    /// memory would feature tomorrow's train of the same number, Live Activity
    /// and all. It lapses `PinStore.ttl` after the pinned train's departure
    /// (after pinning, when the trip isn't known), like a saved pin at launch.
    public static func pinExpired(trip: Trip?, pinnedAt: Date?, now: Date) -> Bool {
        guard let since = trip?.departure ?? pinnedAt else { return false }
        return now.timeIntervalSince(since) > PinStore.ttl
    }

    /// Why a connection can't be made today, read off the connecting train's
    /// own live stop list: it doesn't stop at the transfer station, or NJ
    /// Transit marks that stop cancelled. On 5 October 2026, with Midtown
    /// Direct trains sent to Hoboken, the planner still offered Penn Station to
    /// Watchung Avenue by NEC train 3833 to Secaucus and 6233 from there, but
    /// those trains ran by Newark Broad Street instead (6222's list: Watchung
    /// Avenue ... Newark Broad Street, Hoboken; no Secaucus). Only lists that
    /// can be today's count (see `runsForTrip`); with no list loaded, the
    /// connection stands.
    public static func brokenConnection(_ trip: Trip, runs: Runs) -> String? {
        guard trip.transferCount > 0, let legs = trip.legTrainIds else { return nil }
        let tripRuns = runsForTrip(trip, runs: runs)
        for (index, station) in trip.transferAt.enumerated() where index + 1 < legs.count {
            let train = legs[index + 1]
            guard let stops = tripRuns[train], stops.count > 1 else { continue }
            let ref = Stations.all.values.first { $0.shortLabel == station }?.ref
                ?? StationRef(name: station, shortLabel: station)
            let calls = stops.contains { stop in
                Journey.stopMatchesStation(stop.name, ref) && stop.status?.lowercased().contains("cancel") != true
            }
            if !calls { return "Train \(train) isn't stopping at \(station) today" }
        }
        return nil
    }

    /// `view`, marked cancelled with the reason when its connection can't be
    /// made today (see `brokenConnection`). Cancelled, it never counts as the
    /// better option, and the rider sees why rather than a missing row.
    static func markingBrokenConnection(_ view: TripView, runs: Runs) -> TripView {
        guard !view.cancelled, let reason = brokenConnection(view.trip, runs: runs) else { return view }
        var marked = view
        marked.cancelled = true
        marked.trip.status = .cancelled
        marked.trip.statusNote = reason
        return marked
    }

    /// The stop lists that can belong to this trip's trains. Stop lists are
    /// kept across refreshes, so yesterday's list for a train of the same
    /// number can still be on hand; every time on it lies a day from this trip,
    /// and it would put today's train at the end of its line (the journey dot,
    /// "Past X · next Y", the stops sheet) until today's list loads. A list
    /// with no stop time inside the trip's span, widened by
    /// `Timing.sanityWindow`, is left out; one with no times at all is kept.
    public static func runsForTrip(_ trip: Trip, runs: Runs) -> Runs {
        let start = trip.departure.addingTimeInterval(-Timing.sanityWindow)
        let end = (trip.arrival ?? trip.departure.addingTimeInterval(3 * 3600)).addingTimeInterval(Timing.sanityWindow)
        var ids = trip.legTrainIds ?? []
        if let first = trip.trainId, !ids.contains(first) { ids.insert(first, at: 0) }
        var result: Runs = [:]
        for id in ids {
            guard let stops = runs[id] else { continue }
            let times = stops.compactMap(\.time)
            if times.isEmpty || times.contains(where: { $0 >= start && $0 <= end }) {
                result[id] = stops
            }
        }
        return result
    }

    /// v4's render-time ride cache update: remember the pinned trip while the
    /// pin applies to this direction, forget it once no pin applies.
    public static func updatedRideCache(_ current: RideCache?, state: BoardState) -> RideCache? {
        if let key = state.activePinKey, let trip = state.retainedTrip {
            if current?.key != key || current?.trip != trip {
                return RideCache(key: key, trip: trip)
            }
            return current
        }
        if state.activePinKey == nil { return nil }
        return current
    }
}

/// Per-train track history across refreshes (session only, like v4).
public struct TrackState: Equatable, Sendable {
    public var history: [String: String] = [:]
    public var changes: [String: TrackChange] = [:]
    /// When each train was last in a payload. Keys carry no date and train
    /// numbers repeat every day, so a train unseen for `forgetAfter` is
    /// forgotten before the next payload is compared: otherwise tomorrow's
    /// 1207 leaving Hoboken from another track than today's would read as a
    /// track change.
    public var lastSeen: [String: Date] = [:]
    public static let forgetAfter: TimeInterval = 6 * 3600

    public init() {}

    /// Fold in a freshly fetched payload. Only live payloads count; the first
    /// sighting of a train never counts as a change.
    public mutating func ingest(_ payload: Payload, now: Date) {
        guard payload.source.kind == .live else { return }
        for (key, seen) in lastSeen where now.timeIntervalSince(seen) > Self.forgetAfter {
            history[key] = nil
            lastSeen[key] = nil
        }
        let result = Status.updateTrackHistory(history, trips: payload.trips, now: now)
        for key in payload.trips.compactMap(Status.tripKey) {
            lastSeen[key] = now
        }
        history = result.history
        var merged = Status.pruneTrackChanges(changes, now: now)
        for (key, change) in result.changes { merged[key] = change }
        changes = merged
    }
}

/// Watches the featured train across refreshes and ticks; when it leaves the
/// list after its expected departure has passed, reports it once so the
/// board can say "Train N has departed" while the next departure takes over.
public struct DepartureWatcher: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        var dirKey: String
        var key: String
        var label: String
        var effectiveDeparture: Date
    }

    var previous: Snapshot?

    public init() {}

    /// Returns the train label to announce, if the previous hero just departed.
    public mutating func observe(_ state: BoardState, now: Date) -> String? {
        // Pinned mode has its own lifecycle (ride retention); announcements
        // only make sense for the automatic next-train flow.
        if state.activePinKey != nil {
            previous = nil
            return nil
        }
        var announce: String?
        if let previous, previous.dirKey == state.dirKey, state.feedMode == .live {
            announce = Status.detectDeparture(
                Status.HeroSnapshot(key: previous.key, label: previous.label, effectiveDeparture: previous.effectiveDeparture),
                currentKeys: state.currentKeys,
                now: now
            )
        }
        if let hero = state.hero, let key = hero.key {
            previous = Snapshot(
                dirKey: state.dirKey,
                key: key,
                label: hero.trip.trainId ?? "This train",
                effectiveDeparture: hero.expectedDeparture
            )
        } else {
            previous = nil
        }
        return announce
    }
}
