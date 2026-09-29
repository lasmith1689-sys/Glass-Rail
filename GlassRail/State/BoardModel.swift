import Foundation
import GlassRailKit
import Observation
import WidgetKit

enum ActiveSheet: String, Identifiable {
    case later, stops, settings
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
    var activeSheet: ActiveSheet?

    let demo: DemoScenario?
    private let client = NJTClient()
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

    /// How often the board polls NJ Transit, like v4.
    static let refreshInterval: Duration = .seconds(60)
    /// How often the clock-derived parts (countdowns, direction, departures) update.
    static let tickInterval: Duration = .seconds(10)
    /// A saved payload older than this is not worth showing at launch.
    static let warmStartLimit: TimeInterval = 30 * 60

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
                if let trip = restored.trip {
                    rideCache = RideCache(key: restored.key, trip: trip)
                }
            }
            if let snapshot = store.snapshot,
               snapshot.payload.source.kind == .live,
               Date().timeIntervalSince(snapshot.payload.generatedAt) < Self.warmStartLimit {
                payload = snapshot.payload
                runs = snapshot.runs
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
                    try? await Task.sleep(for: Self.refreshInterval)
                }
            })
        }
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.tick()
            }
        })
        if let sheet = LaunchOptions.sheet.flatMap(ActiveSheet.init(rawValue:)) {
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
        do {
            let fresh = try await client.fetchLivePayload()
            let at = Date()
            trackState.ingest(fresh, now: at)
            payload = fresh
            fetchFailures = 0
            now = at
            persistSnapshot()
            reloadWidgetsIfDue()
        } catch {
            // Keep showing the last live data (it turns STALE after two
            // misses); with nothing to show at all, fall back to the bundled
            // sample, always labeled SAMPLE.
            fetchFailures += 1
            if payload == nil {
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
            fetchFailures: fetchFailures
        )
        var next = BoardEngine.compute(inputs)
        // v4 kept hold of the pinned trip during render; so do we.
        let cache = BoardEngine.updatedRideCache(rideCache, state: next)
        if cache != rideCache {
            rideCache = cache
            inputs.rideCache = cache
            next = BoardEngine.compute(inputs)
        }
        if let label = watcher.observe(next, now: now) {
            showDeparted(label, dirKey: next.dirKey)
        }
        if next != state { state = next }
        scheduleRunsIfNeeded()
        rides.sync(pin: pin, state: state, updatedAt: payload.generatedAt, now: now)
    }

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
        rideCache = RideCache(key: key, trip: view.trip)
        if demo == nil { store.savePin(newPin, trip: view.trip, now: Date()) }
        activeSheet = nil
        recompute()
    }

    /// "Pinned · show next".
    func unpin() {
        pin = nil
        if demo == nil { store.savePin(nil, trip: nil, now: Date()) }
        recompute()
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
        let demoPayload = Demo.payload(scenario, step: step, now: at)
        trackState.ingest(demoPayload, now: at)
        payload = demoPayload
        // Merge like the live path does: live mode keeps fetching the pinned
        // train's stop list after the planner drops it, so the riding
        // scenario keeps its stops too. (v4's demo replaced them.)
        runs.merge(Demo.runs(for: demoPayload, now: at)) { _, new in new }
        now = at
        recompute()
    }
}
