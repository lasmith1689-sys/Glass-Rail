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
    public var later: [TripView]
    public var noService: Bool
    public var alternate: Alternate?
    public var heroStops: [TrainStop]?
    public var heroConnections: [Connection]
    public var currentKeys: [String]
    /// The journey dot, 0...1 along origin to destination.
    public var progress: Double
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
    /// Rows in "Later this way".
    public static let laterMax = 10
    /// How many trains get live stop lists (hero plus visible later rows).
    public static let stopListTrains = 6
    /// How long the "Train N has departed" notice stays up.
    public static let departedNoticeDuration: TimeInterval = 12

    /// True pickup and drop-off times for one trip from its live stop list.
    public static func applyTiming(_ view: TripView, runs: Runs, origin: Station, dest: Station) -> TripView {
        let stops = view.trip.trainId.flatMap { runs[$0] }
        return Timing.withTiming(
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

        let base = Status.selectTripViews(payload.trips, fromId: from.id, toId: to.id, now: now, alerts: alerts, changes: activeChanges)
        let tracked = trackedTrainIds(base: base, pin: input.pin, rideCache: input.rideCache)
        let direction = base
            .map { applyTiming($0, runs: runs, origin: from, dest: to) }
            .stableSorted { $0.expectedDeparture < $1.expectedDeparture }

        // A tapped ("pinned") train takes over the hero card. While upcoming it
        // is picked from the normal list; once it departs it is retained as a
        // ride until shortly after arrival, so the dot can follow the trip.
        let activePinKey = (input.pin?.dirKey == dirKey) ? input.pin?.key : nil
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
            pinnedRide = applyTiming(ride, runs: runs, origin: from, dest: to)
        }
        let hero = pinnedRide ?? upcomingHero
        let isPinned = activePinKey != nil && hero?.key == activePinKey
        var laterSource = direction
        if pinnedRide == nil, let upcomingIndex { laterSource.remove(at: upcomingIndex) }
        let later = Array(laterSource.prefix(laterMax))

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
                let views = Status.selectTripViews(payload.trips, fromId: route.fromId, toId: route.toId, now: now, alerts: alerts, changes: activeChanges)
                if !views.isEmpty, let altFrom = Stations.station(route.fromId), let altTo = Stations.station(route.toId) {
                    alternate = Alternate(from: altFrom, to: altTo, views: Array(views.prefix(3)))
                    break
                }
            }
        }

        let heroStops = hero?.trip.trainId.flatMap { runs[$0] }
        let heroConnections = hero.map { Journey.tripConnections($0.trip, runs: runs) } ?? []

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
            later: later,
            noService: noService,
            alternate: alternate,
            heroStops: heroStops,
            heroConnections: heroConnections,
            currentKeys: direction.compactMap(\.key),
            progress: progress
        )
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

    public init() {}

    /// Fold in a freshly fetched payload. Only live payloads count; the first
    /// sighting of a train never counts as a change.
    public mutating func ingest(_ payload: Payload, now: Date) {
        guard payload.source.kind == .live else { return }
        let result = Status.updateTrackHistory(history, trips: payload.trips, now: now)
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
