import Foundation

/// QA-only scenarios (port of lib/demo.ts). The live feed can't be forced into
/// a delay, a track change or a departure on demand, so the app can be
/// launched with `-GlassRailDemo <scenario>` to render a scripted payload
/// instead of polling (v4 used `?demo=<scenario>`).
public enum DemoScenario: String, CaseIterable, Sendable {
    case delayed
    case track
    case departed
    case stale
    case sample
    case riding
    /// On 1074, which left 12 minutes ago, without having pinned it: the
    /// Later sheet's "On a train that's already left?" offers it.
    case boarded
    /// An evening at New York Penn before the board posts any track: the
    /// checker calls 6263's from the signalling system (Tk 13, 98%) and
    /// 6273's from history (Tk 7, 31%), and has nothing yet for 6283.
    case pennCall

    public static func parse(_ value: String?) -> DemoScenario? {
        guard let value else { return nil }
        return DemoScenario(rawValue: value)
    }

    /// Seconds after launch at which the scenario's second step is applied
    /// (track moves, hero departs, ride drops off the feed), or nil.
    public var secondStepDelay: TimeInterval? {
        switch self {
        case .track: return 4
        case .riding: return 6
        case .departed: return 12
        case .delayed, .stale, .sample, .boarded, .pennCall: return nil
        }
    }
}

public enum Demo {
    static func trip(
        _ fromId: String,
        _ toId: String,
        _ depMins: Int,
        _ durationMins: Int,
        _ trainId: String,
        now: Date,
        _ configure: (inout Trip) -> Void = { _ in }
    ) -> Trip {
        let dep = now.adding(minutes: depMins)
        var trip = Trip(fromId: fromId, toId: toId, trainId: trainId, departure: dep, arrival: dep.adding(minutes: durationMins))
        configure(&trip)
        return trip
    }

    /// The hero's operational overrides (track, status, note), as v4's `Partial<Trip>`.
    struct HeroPatch {
        var track: String?
        var status: TripStatus?
        var statusNote: String?

        func apply(_ trip: inout Trip) {
            if let track { trip.track = track }
            if let status { trip.status = status }
            if let statusNote { trip.statusNote = statusNote }
        }
    }

    static func baseTrips(now: Date, hero: HeroPatch, heroDepMins: Int) -> [Trip] {
        let laterDelayed: (inout Trip) -> Void = hero.status == .delayed
            ? { $0.track = "2"; $0.status = .delayed; $0.statusNote = "Delayed 4 min" }
            : { $0.track = "2" }
        return [
            trip("watchung", "hoboken", heroDepMins, 39, "1074", now: now) { hero.apply(&$0) },
            trip("watchung", "hoboken", heroDepMins + 22, 39, "1078", now: now, laterDelayed),
            trip("watchung", "hoboken", heroDepMins + 52, 39, "1082", now: now),
            trip("watchung", "hoboken", heroDepMins + 82, 39, "1086", now: now),
            trip("watchung", "penn", heroDepMins + 8, 52, "6222", now: now) {
                $0.transferCount = 1
                $0.transferAt = ["Secaucus"]
                $0.track = "2"
            },
            trip("hoboken", "watchung", 21, 39, "1207", now: now) { $0.track = "8" },
        ]
    }

    /// The payload for a scenario. `step` 0 is the first paint, 1 the
    /// follow-up refresh (track moved, hero departed).
    public static func payload(_ scenario: DemoScenario, step: Int, now: Date) -> Payload {
        var trips: [Trip]
        var kind: SourceKind = .live
        var generatedAt = now

        switch scenario {
        case .delayed:
            trips = baseTrips(now: now, hero: HeroPatch(track: "2", status: .delayed, statusNote: "Delayed 6 min"), heroDepMins: 40)
        case .track:
            trips = baseTrips(now: now, hero: HeroPatch(track: step == 0 ? "2" : "3"), heroDepMins: 40)
        case .departed:
            // Step 1 refreshes after the hero's departure moment has passed.
            trips = baseTrips(now: now, hero: HeroPatch(track: "2"), heroDepMins: step == 0 ? 0 : -3)
        case .stale:
            trips = baseTrips(now: now, hero: HeroPatch(track: "2"), heroDepMins: 40)
            generatedAt = now.addingTimeInterval(-Status.staleAfter - 60)
        case .sample:
            kind = .sample
            trips = baseTrips(now: now, hero: HeroPatch(track: "2", status: .delayed, statusNote: "Delayed 10 min"), heroDepMins: 40)
        case .riding:
            // Hero departed 12 min ago, arrives in 27: the pinned-ride state.
            // Step 1 drops it from the payload entirely, as NJ Transit's
            // planner does once a train has left. The board must keep it.
            trips = baseTrips(now: now, hero: HeroPatch(track: "2"), heroDepMins: -12)
            if step == 1 { trips = trips.filter { $0.trainId != "1074" } }
        case .boarded:
            // The riding scenario's trips, nothing pinned: the board features
            // 1078, and 1074 (left 12 minutes ago, arrives in 27) is a ride
            // the rider can still follow.
            trips = baseTrips(now: now, hero: HeroPatch(track: "2"), heroDepMins: -12)
        case .pennCall:
            trips = pennTrips(now: now)
        }

        return Payload(
            generatedAt: generatedAt,
            source: PayloadSource(kind: kind, detail: "Demo scenario: \(scenario.rawValue) (QA preview, not real service data)."),
            trips: trips
        )
    }

    /// The pennCall scenario's trains home from New York Penn, none of them
    /// posted yet.
    static func pennTrips(now: Date) -> [Trip] {
        [
            trip("penn", "watchung", 18, 38, "6263", now: now),
            trip("penn", "watchung", 39, 39, "6273", now: now),
            trip("penn", "watchung", 69, 39, "6283", now: now),
        ]
    }

    /// The track checker's calls for a scenario: only pennCall has any.
    public static func pennTracks(_ scenario: DemoScenario, now: Date) -> PennTracks? {
        guard scenario == .pennCall else { return nil }
        let trips = pennTrips(now: now)
        let calls: [String: TrackCall] = [
            "6263": TrackCall(track: "13", probability: 0.98, source: .signal),
            "6273": TrackCall(track: "7", probability: 0.31, source: .history),
        ]
        return PennTracks(lastPoll: now, departures: trips.map {
            PennTracks.Departure(trainId: $0.trainId ?? "", scheduled: $0.departure, call: calls[$0.trainId ?? ""])
        })
    }

    static let inboundTail = [
        "Lincoln Park",
        "Mountain View",
        "Wayne-Route 23",
        "Little Falls",
        "Montclair State U",
        "Upper Montclair",
    ]
    // Deliberately sparse (express-style) so skipped locals are visible.
    static let midRun = ["Bay Street", "Glen Ridge", "Newark Broad Street"]

    /// Synthetic stop list for a demo train, anchored to its trip times. Stops
    /// in the past are flagged departed, so the position dot, "Past X" label
    /// and stops sheet behave exactly as with live data.
    public static func stops(now: Date, departure: Date, arrival: Date?, originName: String, destName: String) -> [TrainStop] {
        // Seconds since the epoch (v4 used milliseconds; seconds keep whole
        // minutes exact in Double arithmetic).
        let dep = departure.timeIntervalSince1970
        let arr = arrival?.timeIntervalSince1970 ?? dep + 39 * 60
        var points: [(name: String, t: TimeInterval)] = []
        let originIsTerminal = RX.test("hoboken|penn", originName, ignoreCase: true)
        if !originIsTerminal {
            for (index, name) in inboundTail.enumerated() {
                points.append((name, dep - Double(55 - index * 10) * 60))
            }
        }
        points.append((originName, dep))
        let mids = originIsTerminal ? Array(midRun.reversed()) : midRun
        for (index, name) in mids.enumerated() {
            points.append((name, dep + (Double(index + 1) / Double(mids.count + 1)) * (arr - dep)))
        }
        points.append((destName, arr))
        let cutoff = now.timeIntervalSince1970 - 45
        return points.map { point in
            TrainStop(
                name: point.name,
                time: Date(timeIntervalSince1970: point.t),
                departed: point.t <= cutoff,
                status: "OnTime",
                note: nil
            )
        }
    }

    /// Minutes a delayed demo train makes up before its destination.
    static let recoveryMinutes = 4

    /// Stop lists for every train in a demo payload, keyed by train id. Delayed
    /// trains get shifted stop times so the live-timing path sees a real delay.
    public static func runs(for payload: Payload, now: Date) -> Runs {
        var runs: Runs = [:]
        for trip in payload.trips {
            guard let trainId = trip.trainId, runs[trainId] == nil else { continue }
            guard let from = Stations.station(trip.fromId), let to = Stations.station(trip.toId) else { continue }
            let late = Status.parseDelayMinutes(trip.statusNote) ?? 0
            // Real delayed runs claw back time en route (the captured train
            // 1074 left 6 late and reached Hoboken only 2 late).
            let lateOnArrival = max(0, late - recoveryMinutes)
            runs[trainId] = stops(
                now: now,
                departure: trip.departure.adding(minutes: late),
                arrival: trip.arrival?.adding(minutes: lateOnArrival),
                originName: from.name,
                destName: to.name
            )
        }
        return runs
    }
}
