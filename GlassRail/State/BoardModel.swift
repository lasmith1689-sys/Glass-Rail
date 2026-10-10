import Foundation
import GlassRailKit
import Observation
import WidgetKit

enum ActiveSheet: String, Identifiable {
    case later, stops, settings, alerts
    var id: String { rawValue }
}

/// "Train N has departed", shown for 12 seconds in the direction it happened.
struct DepartedNotice: Equatable {
    var label: String
    var dirKey: String
}

/// The board's state and side effects: polling NJ Transit, the clock tick,
/// the rider's choices, and persistence. Everything the screen shows is
/// derived by `BoardEngine.compute`, the port of v4's board.tsx logic.
@MainActor
@Observable
final class BoardModel {
    private(set) var payload: Payload?
    private(set) var runs: Runs = [:]
    private(set) var now = Date()
    private(set) var destinationId: String
    private(set) var modeOverride: ModeOverride?
    private(set) var pin: Pin?
    private(set) var rideCache: RideCache?
    private(set) var fetchFailures = 0
    private(set) var state: BoardState?
    private(set) var departedNotice: DepartedNotice?
    private(set) var departedFading = false
    private(set) var theme: Theme
    /// Bumped whenever a refresh the rider asked for finishes (drives a haptic).
    private(set) var refreshCount = 0
    /// "On a train that's already left?" is asking NJ Transit.
    private(set) var loadingRecentRides = false
    var activeSheet: ActiveSheet?

    let demo: DemoScenario?
    private let client = NJTClient()
    private let pennClient = PennTracksClient()
    private let store: SharedStore
    private let rides = RideActivityController()
    @ObservationIgnored private var trackState = TrackState()
    @ObservationIgnored private var watcher = DepartureWatcher()
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var fetchingPayload = false
    @ObservationIgnored private var fetchingRuns = false
    @ObservationIgnored private var lastRunIds: [String] = []
    @ObservationIgnored private var lastRunsFetch = Date.distantPast
    @ObservationIgnored private var lastWidgetReload = Date.distantPast
    @ObservationIgnored private var started = false
    /// When the current pin was set (restored with it at launch).
    @ObservationIgnored private var pinnedAt: Date?
    @ObservationIgnored private var catchUpScheduled = false
    /// Trips from earlier refreshes (and the last saved board) that have since
    /// left, plus any asked for: NJ Transit stops listing a train once it
    /// leaves, and there may be no signal on board. Feeds `recentRides`.
    @ObservationIgnored private var recentTrips: [Trip] = []
    /// The track checker's calls on New York Penn departures, fetched while
    /// the board shows trains leaving Penn.
    @ObservationIgnored private var pennTracks: PennTracks?
    @ObservationIgnored private var fetchingPennTracks = false
    @ObservationIgnored private var lastPennTracksFetch = Date.distantPast

    /// How often the board polls NJ Transit, like v4.
    static let refreshInterval: Duration = .seconds(60)
    /// After a failed refresh the next try comes this soon, once: a busy feed
    /// on a disrupted morning shouldn't leave the board on old or sample data
    /// for a whole minute.
    static let retryAfterFailure: Duration = .seconds(10)
    /// How often the clock-derived parts (countdowns, direction, departures) update.
    static let tickInterval: Duration = .seconds(10)
    /// A saved payload older than this is not worth showing at launch.
    static let warmStartLimit: TimeInterval = 30 * 60
    /// Two travel alerts in NJ Transit's own words (5 October 2026), for QA.
    static let qaAlerts = [
        "Due to an Amtrak track condition in one of the Hudson River Tunnels, NJ TRANSIT rail service is subject to up to 60-minute delays into and out of Penn Station New York. Midtown Direct trains are being diverted to Hoboken. NJ TRANSIT rail tickets and passes are being cross honored by NJ TRANSIT and private carrier buses and PATH at Newark Penn Station, Hoboken and 33rd Street, New York.",
        "Temporary Rail Service Changes October 11, 2026 \u{2013} November 14, 2026* Portal North Bridge Enters Final Phase of Construction as Work Begins to Put the Second of Two Tracks into Service",
    ]

    init() {
        let store = SharedStore(appGroup: SharedStore.appGroup())
        self.store = store
        demo = LaunchOptions.demo
        destinationId = store.destinationId
        theme = Theme.named(LaunchOptions.theme ?? store.themeId)

        if demo == nil {
            // Restoring must not re-stamp the pin, or opening the app would
            // keep extending its life.
            if let restored = store.restorePin(now: Date()) {
                pin = restored.pin
                pinnedAt = restored.at
                if let trip = restored.trip {
                    rideCache = RideCache(key: restored.key, trip: trip)
                }
            }
            if let snapshot = store.snapshot,
               snapshot.payload.source.kind == .live,
               snapshot.payload.trips.isEmpty || snapshot.payload.trips.contains(where: { $0.fromId == UserConfig.homeId || $0.toId == UserConfig.homeId }),
               Date().timeIntervalSince(snapshot.payload.generatedAt) < Self.warmStartLimit {
                payload = snapshot.payload
                runs = snapshot.runs
            } else if let snapshot = store.snapshot, snapshot.payload.source.kind == .live {
                // Too old to show, but it may know the train the rider boarded.
                rememberRecent(snapshot.payload.trips, now: Date())
            }
        }
        recompute()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if let demo {
            runDemo(demo)
        } else {
            loops.append(Task { [weak self] in
                while !Task.isCancelled {
                    await self?.loadLive()
                    let retrySoon = self?.fetchFailures == 1
                    try? await Task.sleep(for: retrySoon ? Self.retryAfterFailure : Self.refreshInterval)
                }
            })
        }
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.tick()
            }
        })
        if let sheet = LaunchOptions.sheet.flatMap({ $0 == "home" ? ActiveSheet.settings : $0 == "earlier" ? ActiveSheet.later : ActiveSheet(rawValue: $0) }) {
            loops.append(Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                self?.activeSheet = sheet
            })
        }
    }

    /// Back in the foreground: catch the clock up and refresh right away.
    /// A ride that is still on gets a live Live Activity again.
    func becameActive() {
        rides.resume()
        tick()
        guard started, demo == nil else { return }
        Task { await loadLive() }
    }

    /// Going to the background, possibly for good: hand the pinned ride's
    /// Live Activity over to the system with a dismissal date, so it leaves
    /// the Lock Screen when the ride is over even if the app never runs again.
    func enteredBackground() {
        rides.suspend(now: Date())
    }

    func tick() {
        now = Date()
        recompute()
    }

    // MARK: Data

    /// Pull to refresh and the Refresh button.
    func refresh() async {
        guard demo == nil else {
            refreshCount += 1
            return
        }
        while fetchingPayload {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await loadLive()
        if let ids = state?.trackedTrainIds, !ids.isEmpty {
            await loadRuns(ids)
        }
        refreshCount += 1
    }

    private func loadLive() async {
        guard demo == nil, !fetchingPayload else { return }
        fetchingPayload = true
        let home = UserConfig.homeId
        defer {
            // The rider chose another home while this was in flight: its
            // answer was for the old one, so ask again.
            if home != UserConfig.homeId { Task { await loadLive() } }
        }
        do {
            // Only the direction on screen has to refresh. Any other direction
            // whose lookup fails keeps its previous trips, which age (and turn
            // STALE) on their own clock if the rider switches to it.
            let fresh = try await client.fetchLivePayload(
                required: [shownPair.key],
                previous: payload?.source.kind == .live ? payload : nil
            )
            guard home == UserConfig.homeId else {
                fetchingPayload = false
                return
            }
            let at = Date()
            trackState.ingest(fresh, now: at)
            if payload?.source.kind == .live { rememberRecent(payload?.trips ?? [], now: at) }
            payload = fresh
            fetchFailures = 0
            now = at
            persistSnapshot()
            reloadWidgetsIfDue()
        } catch {
            guard home == UserConfig.homeId else {
                fetchingPayload = false
                return
            }
            // The direction on screen didn't refresh. Keep showing the last
            // live data (it turns STALE after two misses); with nothing to
            // show at all, fall back to the bundled sample, always labeled
            // SAMPLE.
            fetchFailures += 1
            // Rebuilt on every failure, so a long outage doesn't run the
            // sample's times out into "No more trains this way".
            if payload == nil || payload?.source.kind == .sample {
                payload = SampleFixture.payload(
                    now: Date(),
                    detail: "Live NJ Transit feed unavailable, showing sample data. (\(error.localizedDescription))"
                )
            }
            now = Date()
        }
        fetchingPayload = false
        recompute()
    }

    /// Live stop lists drive the true pickup and drop-off times. Merging by
    /// train id means a slow response can only add data, never blank it out.
    private func loadRuns(_ ids: [String]) async {
        guard demo == nil, !fetchingRuns, !ids.isEmpty else { return }
        fetchingRuns = true
        lastRunIds = ids
        lastRunsFetch = Date()
        let fresh = await client.fetchTrainRuns(ids)
        fetchingRuns = false
        guard !fresh.isEmpty else { return }
        runs.merge(fresh) { _, new in new }
        persistSnapshot()
        recompute()
    }

    /// The direction the board shows right now (by clock, destination and
    /// any flip), which a refresh must not fail for.
    private var shownPair: ODPair {
        if let state { return ODPair(fromId: state.from.id, toId: state.to.id) }
        let at = Date()
        return BoardEngine.shownPair(now: at, destinationId: destinationId, modeOverride: Direction.effectiveOverride(modeOverride, now: at))
    }

    /// The board just switched to a direction whose trips didn't come from the
    /// last refresh (its lookup failed then, so they were carried over): fetch
    /// now rather than at the next minute, once any refresh in flight is done.
    private func catchUpIfShowingCarriedData() {
        guard demo == nil, !catchUpScheduled, let state, let payload,
              payload.source.kind == .live, payload.isCarriedOver(pair: state.dirKey) else { return }
        catchUpScheduled = true
        Task { [weak self] in
            while self?.fetchingPayload == true {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self else { return }
            self.catchUpScheduled = false
            guard let state = self.state, self.payload?.isCarriedOver(pair: state.dirKey) == true else { return }
            await self.loadLive()
        }
    }

    /// While the board shows trains leaving New York Penn, the checker's calls
    /// are fetched once a minute (its own pace), and at once when the board
    /// turns to Penn.
    private func schedulePennTracksIfNeeded() {
        guard demo == nil, !fetchingPennTracks, state?.from.id == "penn",
              Date().timeIntervalSince(lastPennTracksFetch) >= 55 else { return }
        Task { await loadPennTracks() }
    }

    private func loadPennTracks() async {
        guard demo == nil, !fetchingPennTracks else { return }
        fetchingPennTracks = true
        lastPennTracksFetch = Date()
        defer { fetchingPennTracks = false }
        // A miss changes nothing: the board just waits for NJ Transit's own
        // track, and a call older than `PennTracks.freshFor` stops showing.
        guard let fresh = try? await pennClient.fetch() else { return }
        pennTracks = fresh
        recompute()
    }

    private func scheduleRunsIfNeeded() {
        guard demo == nil, !fetchingRuns, let ids = state?.trackedTrainIds, !ids.isEmpty else { return }
        if ids != lastRunIds || Date().timeIntervalSince(lastRunsFetch) >= 60 {
            Task { await loadRuns(ids) }
        }
    }

    private func persistSnapshot() {
        guard demo == nil, let payload, payload.source.kind == .live else { return }
        var wanted = Set(payload.trips.compactMap(\.trainId))
        for trip in payload.trips { wanted.formUnion(trip.legTrainIds ?? []) }
        if let rideCache { wanted.formUnion([rideCache.trip.trainId].compactMap { $0 } + (rideCache.trip.legTrainIds ?? [])) }
        store.snapshot = SharedStore.Snapshot(payload: payload, runs: runs.filter { wanted.contains($0.key) })
    }

    private func reloadWidgetsIfDue(force: Bool = false) {
        guard demo == nil else { return }
        if force || Date().timeIntervalSince(lastWidgetReload) >= 5 * 60 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Derivation

    private func recompute() {
        guard let payload else {
            state = nil
            return
        }
        // A pin lapses 3 hours after its train left (see BoardEngine.pinExpired).
        if pin != nil, BoardEngine.pinExpired(trip: rideCache?.trip, pinnedAt: pinnedAt, now: now) {
            releasePin()
        }
        let override = Direction.effectiveOverride(modeOverride, now: now)
        if modeOverride != nil && override == nil { modeOverride = nil }
        var inputs = BoardInputs(
            payload: payload,
            runs: runs,
            now: now,
            destinationId: destinationId,
            modeOverride: override,
            pin: pin,
            rideCache: rideCache,
            trackChanges: trackState.changes,
            fetchFailures: fetchFailures,
            recentTrips: recentTrips,
            pennTracks: pennTracks
        )
        var next = BoardEngine.compute(inputs)
        // v4 kept hold of the pinned trip during render; so do we, for as long
        // as the pin lasts, even while the other direction is on screen.
        let cache = BoardEngine.updatedRideCache(rideCache, state: next, pin: pin)
        if cache != rideCache {
            rideCache = cache
            inputs.rideCache = cache
            next = BoardEngine.compute(inputs)
        }
        // Once the pinned ride is over the pin has done its job: let it go, so
        // "Train N has departed" comes back and tomorrow's train of the same
        // number is never pinned.
        if next.pinRideOver {
            releasePin()
            inputs.pin = nil
            inputs.rideCache = nil
            next = BoardEngine.compute(inputs)
        }
        if let label = watcher.observe(next, now: now) {
            showDeparted(label, dirKey: next.dirKey)
        }
        let switched = next.dirKey != state?.dirKey
        if next != state { state = next }
        scheduleRunsIfNeeded()
        schedulePennTracksIfNeeded()
        if switched { catchUpIfShowingCarriedData() }
        // The ride's times are as old as its direction's trips.
        rides.sync(pin: pin, state: state, updatedAt: next.dataUpdatedAt, now: now)
    }

    /// When the trips on screen were fetched (nil: never, for this direction).
    var dataUpdatedAt: Date? { state?.dataUpdatedAt }

    private func showDeparted(_ label: String, dirKey: String) {
        departedNotice = DepartedNotice(label: label, dirKey: dirKey)
        departedFading = false
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BoardEngine.departedNoticeDuration - 2))
            guard !Task.isCancelled else { return }
            self?.departedFading = true
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.departedNotice = nil
        }
    }

    /// The departed notice, when it belongs to the direction on screen.
    var visibleDepartedLabel: String? {
        guard let notice = departedNotice, notice.dirKey == state?.dirKey else { return nil }
        return notice.label
    }

    var isLoading: Bool { payload == nil }

    // MARK: Rider actions

    func selectDestination(_ id: String) {
        guard id != destinationId, UserConfig.destinationIds.contains(id) else { return }
        destinationId = id
        if demo == nil {
            store.destinationId = id
            reloadWidgetsIfDue(force: true)
        }
        recompute()
    }

    /// Flip AM/PM by hand. The flip holds until the clock next crosses a
    /// direction boundary, then the automatic switch takes over again.
    func flipDirection() {
        guard let mode = state?.commuteMode else { return }
        modeOverride = ModeOverride(mode: mode.flipped, at: Date())
        recompute()
    }

    /// Feature a later train on the main card, remembered for 3 hours with
    /// the trip itself (the planner stops listing a train once it leaves).
    func pinTrip(_ view: TripView) {
        guard let key = view.key, let dirKey = state?.dirKey else { return }
        let newPin = Pin(dirKey: dirKey, key: key)
        pin = newPin
        pinnedAt = Date()
        rideCache = RideCache(key: key, trip: view.trip)
        if demo == nil { store.savePin(newPin, trip: view.trip, now: Date()) }
        activeSheet = nil
        recompute()
    }

    /// "On a train that's already left?" (the Later sheet): ask NJ Transit for
    /// this way's trips of the last hour, on top of those remembered, so the
    /// rider can pick the train they boarded without pinning.
    func loadRecentRides() async {
        guard demo == nil, !loadingRecentRides, let state else { return }
        loadingRecentRides = true
        let found = await client.fetchRecentTrips(for: ODPair(fromId: state.from.id, toId: state.to.id))
        loadingRecentRides = false
        rememberRecent(found, now: Date())
        recompute()
    }

    /// Keep the trips that have left within the last hour and a half (beyond
    /// `BoardEngine.recentRideWindow`), one per train and departure, newest
    /// data winning; forget the rest.
    private func rememberRecent(_ trips: [Trip], now: Date) {
        let since = now.addingTimeInterval(-BoardEngine.recentRideWindow - 15 * 60)
        var kept: [String: Trip] = [:]
        for trip in recentTrips + trips where trip.departure >= since && trip.departure < now {
            guard let key = Status.tripKey(trip) else { continue }
            kept["\(key)|\(trip.departure.timeIntervalSince1970)"] = trip
        }
        recentTrips = Array(kept.values)
    }

    /// The follow button on the main card: pin the featured train itself, Live
    /// Activity and all (v4 could only pin a later train).
    func followHero() {
        guard let hero = state?.hero else { return }
        pinTrip(hero)
    }

    /// The rider's home station (Settings).
    var homeId: String { UserConfig.homeId }
    var home: Station { UserConfig.home }

    /// Settings › Home station: start over from the new home, without the old
    /// one's trips, pin, stop lists or saved board, and fetch it straight away.
    func selectHome(_ id: String) {
        guard demo == nil, id != UserConfig.homeId else {
            activeSheet = nil
            return
        }
        HomeStation.set(id)
        releasePin()
        payload = nil
        runs = [:]
        recentTrips = []
        trackState = TrackState()
        watcher = DepartureWatcher()
        fetchFailures = 0
        store.snapshot = nil
        activeSheet = nil
        recompute()
        reloadWidgetsIfDue(force: true)
        Task { await refresh() }
    }

    /// "Pinned · show next".
    func unpin() {
        releasePin()
        recompute()
    }

    /// Forget the pin and its ride, here and in storage.
    private func releasePin() {
        pin = nil
        pinnedAt = nil
        rideCache = nil
        if demo == nil { store.savePin(nil, trip: nil, now: Date()) }
    }

    func selectTheme(_ newTheme: Theme) {
        theme = newTheme
        if demo == nil {
            store.themeId = newTheme.id
            reloadWidgetsIfDue(force: true)
        }
    }

    // MARK: QA scenarios

    private func runDemo(_ scenario: DemoScenario) {
        // Demo payloads are AM-direction; show them whatever the wall clock
        // says, and pre-pin the ride scenario (as v4 did).
        destinationId = "hoboken"
        modeOverride = ModeOverride(mode: .am, at: Date())
        if scenario == .riding {
            pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1074")
        }
        if scenario == .pennCall {
            // An evening at Penn, whatever the hour of the test.
            destinationId = "penn"
            modeOverride = ModeOverride(mode: .pm, at: Date())
        }
        applyDemo(scenario, step: 0)
        if let delay = scenario.secondStepDelay {
            loops.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.applyDemo(scenario, step: 1)
            })
        }
    }

    private func applyDemo(_ scenario: DemoScenario, step: Int) {
        let at = Date()
        var demoPayload = Demo.payload(scenario, step: step, now: at)
        if LaunchOptions.alerts {
            demoPayload.alerts = Self.qaAlerts
        }
        trackState.ingest(demoPayload, now: at)
        payload = demoPayload
        pennTracks = Demo.pennTracks(scenario, now: at)
        // Merge like the live path does: live mode keeps fetching the pinned
        // train's stop list after the planner drops it, so the riding
        // scenario keeps its stops too. (v4's demo replaced them.) The Penn
        // scenario has none: the made-up runs start out past Lincoln Park.
        if scenario != .pennCall {
            runs.merge(Demo.runs(for: demoPayload, now: at)) { _, new in new }
        }
        now = at
        recompute()
    }
}
