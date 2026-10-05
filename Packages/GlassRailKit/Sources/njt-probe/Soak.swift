import Foundation
import GlassRailKit

// A live stress test: the app's refresh loop run against NJ Transit for a few
// minutes the way the phone runs it (one client, so per-train answers are
// cached; each refresh built on the last; stop lists for the trains on screen),
// checked every round against NJ Transit's own board for Watchung Avenue,
// fetched separately as the referee. Each round, for both terminals:
// - every train on the board bound for the city in the next 6 hours (as far
//   as the board lists them) must be in the app's trips, and on screen
//   unless a later trip beats it;
// - a train the board counts down to ("in 7 Min") must be shown within 3
//   minutes of that time;
// - no train may be shown direct to a terminal its board says it doesn't reach.
// And home: every train on Watchung Avenue's board coming out of the city in
// the next 2 hours that is still on Hoboken's or Penn Station's board (so it
// hasn't left there) must be a way home from that terminal, on screen in PM
// mode, and shown within 3 minutes of that board's countdown; and a connection
// leading the board must be one the connecting train's own stop list allows
// (it calls at the transfer station). And from the second round on (the
// first refresh after opening looks up only the direction on screen), every
// train coming out of the city on Watchung Avenue's board from 75 minutes to
// 6 hours ahead must end a way home from Hoboken or Penn Station: the
// terminals' boards only list the next hour or two. A failed refresh or any
// problem fails the step; the CI step is informational.

/// Counts requests, so each round can say what it cost.
final class CountingTransport: NJTTransport, @unchecked Sendable {
    let inner: any NJTTransport
    private let lock = NSLock()
    private var count = 0

    init(_ inner: any NJTTransport) {
        self.inner = inner
    }

    func send(_ body: Data) async throws -> NJTHTTPResponse {
        lock.lock()
        count += 1
        lock.unlock()
        return try await inner.send(body)
    }

    func take() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let taken = count
        count = 0
        return taken
    }
}

func runSoak(rounds: Int, interval: TimeInterval) async -> Bool {
    let transport = CountingTransport(URLSessionTransport(timeout: 20))
    let app = NJTClient(transport: transport)
    let referee = NJTClient()
    var payload: Payload?
    var runs: Runs = [:]
    var seconds: [Double] = []
    var requests: [Int] = []
    var failedRefreshes = 0
    var problems: [String] = []
    var notes: [String] = []
    var log: [String] = []
    print("Soak: \(rounds) refreshes, \(Int(interval)) s apart, from \(Format.time(Date())) Eastern")
    /// How far ahead the referee's board is held against the app: as far as
    /// the app looks up each train on it (`NJTQueries.seedHorizonMinutes`).
    let boardReach = TimeInterval(NJTQueries.seedHorizonMinutes * 60)

    /// A train past its time that the referee's board still lists with no
    /// countdown, which the app dropped because NJ Transit's own data said it
    /// had gone: its stop list marks it departed from the station, or the
    /// app's own read of the board no longer listed it. The referee's board,
    /// cached for up to 30 seconds, lags; a countdown still means it's coming.
    func departed(_ train: String, scheduled: Date, entry: BoardEntry, at station: Station, trips: [Trip], now: Date) -> Bool {
        guard scheduled < now, entry.countdownMinutes == nil else { return false }
        let stop = runs[train]?.first { Journey.stopMatchesStation($0.name, station.ref) }
        return stop?.departed == true || trips.allSatisfy { $0.listedAt == nil }
    }

    /// The time shown is within 3 minutes of the board's countdown or of the
    /// train's live stop time at the station (the app shows the live time,
    /// which can be a minute or two before the board's: trains leave early).
    func supported(_ shown: Date, board: Date, train: String, at station: Station) -> Bool {
        if abs(shown.timeIntervalSince(board)) <= 3 * 60 { return true }
        guard let live = runs[train]?.first(where: { Journey.stopMatchesStation($0.name, station.ref) })?.time else { return false }
        return abs(shown.timeIntervalSince(live)) <= 3 * 60
    }

    for round in 1...rounds {
        if round > 1 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
        let started = Date()
        let shown = BoardEngine.shownPair(now: started, destinationId: "hoboken", modeOverride: nil)
        do {
            payload = try await app.fetchLivePayload(required: [shown.key], previous: payload?.source.kind == .live ? payload : nil)
        } catch {
            failedRefreshes += 1
            problems.append("round \(round): refresh failed: \(error.localizedDescription)")
        }
        seconds.append(Date().timeIntervalSince(started))
        guard let payload else { continue }

        // Stop lists for the trains each direction shows, as the app loads
        // them while that direction is on screen (so the ride home is checked
        // as the rider would see it in the morning too).
        let now = Date()
        for destination in ["hoboken", "penn"] {
            for mode in [CommuteMode.am, .pm] {
                let ids = BoardEngine.compute(BoardInputs(
                    payload: payload, runs: runs, now: now, destinationId: destination,
                    modeOverride: ModeOverride(mode: mode, at: now)
                )).trackedTrainIds
                runs.merge(await app.fetchTrainRuns(ids)) { _, new in new }
            }
        }
        requests.append(transport.take())

        guard let items = try? await referee.fetchDepartureBoard("Watchung Avenue") else {
            notes.append("round \(round): the referee's board didn't load")
            continue
        }
        let truthAt = Date()
        let board = NJTParse.buildBoardIndex(items)
        var line = "round \(round) (\(String(format: "%.1f", seconds.last ?? 0)) s, \(requests.last ?? 0) requests):"

        for destination in ["hoboken", "penn"] {
            let state = BoardEngine.compute(BoardInputs(
                payload: payload, runs: runs, now: truthAt, destinationId: destination,
                modeOverride: ModeOverride(mode: .am, at: truthAt)
            ))
            let trips = payload.trips.filter { $0.fromId == UserConfig.homeId && $0.toId == destination }
            for (train, entry) in board where NJTParse.isTowardCity(entry.destination) {
                guard let scheduled = entry.departureRaw.flatMap({ NJTParse.rawToDate($0, baseNow: truthAt) }),
                      scheduled <= truthAt.addingTimeInterval(boardReach) else { continue }
                let mine = trips.filter { $0.trainId == train }
                if mine.isEmpty {
                    problems.append("round \(round) \(destination): \(train) \(Format.time(scheduled)) to \(entry.destination ?? "?") is on Watchung Avenue's board but not in the app")
                    continue
                }
                guard let view = state.direction.first(where: { $0.trip.trainId == train }) else {
                    if mine.allSatisfy({ $0.transferCount > 0 }) {
                        notes.append("round \(round) \(destination): \(train) left out, a later trip beats it")
                    } else if departed(train, scheduled: scheduled, entry: entry, at: Stations.watchung, trips: mine, now: truthAt) {
                        notes.append("round \(round) \(destination): \(train) \(Format.time(scheduled)) dropped as gone, as NJ Transit's own data said; the referee's board still listed it")
                    } else {
                        problems.append("round \(round) \(destination): \(train) \(Format.time(scheduled)) is in the app's trips but not on screen")
                    }
                    continue
                }
                if let countdown = entry.countdownMinutes {
                    let real = truthAt.addingTimeInterval(Double(countdown) * 60)
                    if !supported(view.expectedDeparture, board: real, train: train, at: Stations.watchung) {
                        problems.append("round \(round) \(destination): \(train) shows \(Format.time(view.expectedDeparture)), the board says \(Format.time(real)) (in \(countdown) min)")
                    }
                }
                if view.trip.transferCount == 0, view.trip.terminus == nil, NJTParse.servedTerminal(entry.destination) != destination {
                    problems.append("round \(round) \(destination): \(train) shown direct to \(destination), the board says \(entry.destination ?? "?")")
                }
            }
            if let hero = state.hero {
                line += " \(destination): \(hero.trip.trainId ?? "?") \(Format.time(hero.expectedDeparture)) \(Format.tripType(hero.trip))\(hero.delayed ? " late" : "");"
            } else {
                line += " \(destination): no train;"
            }
        }

        // The ride home, refereed by the terminals' own boards.
        for terminal in ["hoboken", "penn"] {
            guard let name = Stations.station(terminal)?.name,
                  let items = try? await referee.fetchDepartureBoard(name) else {
                notes.append("round \(round): the referee's \(terminal) board didn't load")
                continue
            }
            let terminalBoard = NJTParse.buildBoardIndex(items)
            let checkedAt = Date()
            let state = BoardEngine.compute(BoardInputs(
                payload: payload, runs: runs, now: checkedAt, destinationId: terminal,
                modeOverride: ModeOverride(mode: .pm, at: checkedAt)
            ))
            for (train, atHome) in board where !NJTParse.isTowardCity(atHome.destination) {
                guard let there = terminalBoard[train],
                      let leaves = there.departureRaw.flatMap({ NJTParse.rawToDate($0, baseNow: checkedAt) }),
                      leaves <= checkedAt.addingTimeInterval(2 * 3600) else { continue }
                let rides = payload.trips.filter {
                    $0.fromId == terminal && $0.toId == UserConfig.homeId && ($0.legTrainIds?.last ?? $0.trainId) == train
                }
                if rides.isEmpty {
                    problems.append("round \(round) home from \(terminal): \(train) \(Format.time(leaves)) is on its board and Watchung Avenue's but in no way home")
                    continue
                }
                guard let view = state.direction.first(where: { $0.trip.trainId == train && $0.trip.transferCount == 0 }) else {
                    if let station = Stations.station(terminal),
                       departed(train, scheduled: leaves, entry: there, at: station, trips: rides, now: checkedAt) {
                        notes.append("round \(round) home from \(terminal): \(train) \(Format.time(leaves)) dropped as gone, as NJ Transit's own data said; the referee's board still listed it")
                        continue
                    }
                    problems.append("round \(round) home from \(terminal): \(train) \(Format.time(leaves)) is in the app's trips but not on screen as a direct ride")
                    continue
                }
                if let countdown = there.countdownMinutes, let station = Stations.station(terminal) {
                    let real = checkedAt.addingTimeInterval(Double(countdown) * 60)
                    if !supported(view.expectedDeparture, board: real, train: train, at: station) {
                        problems.append("round \(round) home from \(terminal): \(train) shows \(Format.time(view.expectedDeparture)), the board says \(Format.time(real)) (in \(countdown) min)")
                    }
                }
            }
            // A connection the rider is told to make must exist: the connecting
            // train's own stop list must call at the transfer station.
            if let hero = state.hero, !hero.cancelled, hero.trip.transferCount > 0 {
                let legs = Array((hero.trip.legTrainIds ?? []).dropFirst())
                if let reason = BoardEngine.brokenConnection(hero.trip, runs: await referee.fetchTrainRuns(legs)) {
                    problems.append("round \(round) home from \(terminal): \(hero.trip.trainId ?? "?") \(Format.time(hero.expectedDeparture)) leads the board, but \(reason)")
                }
            }
            if let hero = state.hero {
                line += " home from \(terminal): \(hero.trip.trainId ?? "?") \(Format.time(hero.expectedDeparture)) \(Format.tripType(hero.trip))\(hero.delayed ? " late" : "")\(hero.cancelled ? " cancelled" : "");"
            } else {
                line += " home from \(terminal): no train;"
            }
        }

        // Every train home on Watchung Avenue's board must end a way home:
        // the terminals' boards above only reach an hour or two, and the
        // planner, asked by the clock alone, skips trains. From 75 minutes on,
        // so the ride has not already left the terminal.
        if round > 1 {
            for (train, atHome) in board where !NJTParse.isTowardCity(atHome.destination) {
                guard let arrives = atHome.departureRaw.flatMap({ NJTParse.rawToDate($0, baseNow: truthAt) }),
                      arrives > truthAt.addingTimeInterval(75 * 60),
                      arrives <= truthAt.addingTimeInterval(boardReach) else { continue }
                let ends = payload.trips.contains {
                    ["hoboken", "penn"].contains($0.fromId) && $0.toId == UserConfig.homeId && ($0.legTrainIds?.last ?? $0.trainId) == train
                }
                if !ends {
                    problems.append("round \(round): \(train) reaching Watchung Avenue at \(Format.time(arrives)) ends no way home from Hoboken or Penn Station")
                }
            }
        }
        log.append(line)
    }

    let sorted = seconds.sorted()
    func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
    var summary = [
        "\(rounds - failedRefreshes) of \(rounds) refreshes answered; seconds p50 \(String(format: "%.1f", percentile(0.5))), p90 \(String(format: "%.1f", percentile(0.9))), max \(String(format: "%.1f", sorted.last ?? 0)); requests per round \(requests.map(String.init).joined(separator: ", "))",
    ]
    summary += log
    func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
    let uniqueProblems = unique(problems)
    let uniqueNotes = unique(notes)
    summary.append(uniqueProblems.isEmpty ? "No problems." : "\(uniqueProblems.count) problems:")
    summary += uniqueProblems.prefix(20)
    if !uniqueNotes.isEmpty {
        summary.append("Notes:")
        summary += uniqueNotes.prefix(15)
    }
    notice("soak", summary.joined(separator: "\n"))
    print(summary.joined(separator: "\n"))
    return uniqueProblems.isEmpty
}
