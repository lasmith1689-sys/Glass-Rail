import Foundation
import GlassRailKit

// A live stress test: the app's refresh loop run against NJ Transit for a few
// minutes the way the phone runs it (one client, so per-train answers are
// cached; each refresh built on the last; stop lists for the trains on screen),
// checked every round against NJ Transit's own board for Watchung Avenue,
// fetched separately as the referee. Each round, for both terminals:
// - every train on the board bound for the city in the next 2 hours must be
//   in the app's trips, and on screen unless a later trip beats it;
// - a train the board counts down to ("in 7 Min") must be shown within 3
//   minutes of that time;
// - no train may be shown direct to a terminal its board says it doesn't reach.
// Trains home (out of the city) missing from the app are reported too. A
// failed refresh or any problem fails the step; the CI step is informational.

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

        // Stop lists for the trains on screen, as the app loads them.
        let now = Date()
        var tracked: [String] = []
        for destination in ["hoboken", "penn"] {
            for id in BoardEngine.compute(BoardInputs(payload: payload, runs: runs, now: now, destinationId: destination)).trackedTrainIds where !tracked.contains(id) {
                tracked.append(id)
            }
        }
        runs.merge(await app.fetchTrainRuns(Array(tracked.prefix(NJTQueries.maxStopListTrains)))) { _, new in new }
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
                      scheduled <= truthAt.addingTimeInterval(2 * 3600) else { continue }
                let mine = trips.filter { $0.trainId == train }
                if mine.isEmpty {
                    problems.append("round \(round) \(destination): \(train) \(Format.time(scheduled)) to \(entry.destination ?? "?") is on Watchung Avenue's board but not in the app")
                    continue
                }
                guard let view = state.direction.first(where: { $0.trip.trainId == train }) else {
                    if mine.allSatisfy({ $0.transferCount > 0 }) {
                        notes.append("round \(round) \(destination): \(train) left out, a later trip beats it")
                    } else {
                        problems.append("round \(round) \(destination): \(train) \(Format.time(scheduled)) is in the app's trips but not on screen")
                    }
                    continue
                }
                if let countdown = entry.countdownMinutes {
                    let real = truthAt.addingTimeInterval(Double(countdown) * 60)
                    if abs(view.expectedDeparture.timeIntervalSince(real)) > 3 * 60 {
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

        // Trains coming out of the city, which take riders home.
        for (train, entry) in board where !NJTParse.isTowardCity(entry.destination) {
            guard let atHome = entry.departureRaw.flatMap({ NJTParse.rawToDate($0, baseNow: truthAt) }),
                  atHome <= truthAt.addingTimeInterval(2 * 3600) else { continue }
            let home = payload.trips.filter { $0.toId == UserConfig.homeId && ($0.legTrainIds?.last ?? $0.trainId) == train }
            if home.isEmpty {
                notes.append("round \(round): \(train) reaching Watchung Avenue at \(Format.time(atHome)) is in no trip home")
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
