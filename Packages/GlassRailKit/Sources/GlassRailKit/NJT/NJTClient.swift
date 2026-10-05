import Foundation

/// A raw HTTP reply, so tests can stand in for NJ Transit.
public struct NJTHTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Sends one GraphQL POST body and returns the reply.
public protocol NJTTransport: Sendable {
    func send(_ body: Data) async throws -> NJTHTTPResponse
}

/// The real transport: a POST to NJ Transit with v4's single header.
public struct URLSessionTransport: NJTTransport {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func send(_ body: Data) async throws -> NJTHTTPResponse {
        var request = URLRequest(url: NJTQueries.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return NJTHTTPResponse(status: status, body: data)
    }
}

/// Talks to NJ Transit directly from the phone. Port of the fetch functions in
/// lib/njt.ts (v4 ran these on a server; there is no server now).
public struct NJTClient: Sendable {
    public var transport: any NJTTransport
    public var clock: @Sendable () -> Date
    /// Answers to per-train lookups, reused across refreshes (see `PlannerCache`).
    public var plannerCache: PlannerCache
    /// How long to wait before trying a failed request again (see `reply`).
    public var retryDelay: TimeInterval

    public init(
        transport: any NJTTransport = URLSessionTransport(),
        clock: @escaping @Sendable () -> Date = { Date() },
        plannerCache: PlannerCache = PlannerCache(),
        retryDelay: TimeInterval = 0.4
    ) {
        self.transport = transport
        self.clock = clock
        self.plannerCache = plannerCache
        self.retryDelay = retryDelay
    }

    // MARK: GraphQL

    /// POST a query and return its `data` object, throwing NJT's own error text.
    public func post(query: String, variables: [String: GQLValue]) async throws -> JSON {
        try Self.data(of: try await reply(query: query, variables: variables))
    }

    /// POST a query and return the whole reply once it is known to be JSON
    /// with a 2xx status (checked in v4's order), before looking at `errors`
    /// or `data`. A failure that is likely to pass (a dropped connection, a
    /// 5xx or 429, an HTML error page) is tried once more after `retryDelay`;
    /// a timeout already waited long enough and is not.
    func reply(query: String, variables: [String: GQLValue]) async throws -> JSON {
        let object: [String: Any] = [
            "query": query,
            "variables": variables.mapValues { $0.jsonObject },
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        do {
            return try await attempt(body)
        } catch {
            guard Self.worthRetrying(error) else { throw error }
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            return try await attempt(body)
        }
    }

    static func worthRetrying(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            return urlError.code != .timedOut && urlError.code != .cancelled
        }
        switch error as? NJTError {
        case .http(let status)?: return status == 429 || status >= 500
        case .notJSON?: return true
        default: return false
        }
    }

    /// One POST, checked as `reply` describes.
    private func attempt(_ body: Data) async throws -> JSON {
        let response = try await transport.send(body)
        let payload: JSON
        do {
            payload = try JSON.parse(response.body)
        } catch {
            // v4 parsed the body before checking the status, so a non-JSON
            // error page surfaced as a parse failure.
            throw NJTError.notJSON
        }
        guard (200..<300).contains(response.status) else {
            throw NJTError.http(response.status)
        }
        return payload
    }

    /// A reply's `data` object, throwing NJT's own error text.
    static func data(of payload: JSON) throws -> JSON {
        if let errors = payload["errors"]?.arrayValue, !errors.isEmpty {
            let message = errors
                .map { $0["message"].jsString }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            throw NJTError.graphQL(message.isEmpty ? "NJT GraphQL error" : message)
        }
        guard let data = payload["data"], data.truthy else {
            throw NJTError.missingData
        }
        return data
    }

    public func fetchDepartureBoard(_ stationName: String) async throws -> [JSON] {
        let data = try await post(query: NJTQueries.departureBoard, variables: ["station": .string(stationName)])
        return data["getTrainDepartureScreens"]?["items"]?.arrayValue ?? []
    }

    /// Itineraries from `origin` to `destination` leaving from `moment` on,
    /// or with `arriveBy`, arriving by `moment` (latest departure first).
    /// Empty when NJ Transit says there are none: it reports that as a
    /// GraphQL error, not an empty list (see `NJTParse.isNoTripsReply`), and
    /// that one reply is an answer, not a failure. Every other error throws.
    public func fetchTripPlanner(origin: String, destination: String, at moment: Date, arriveBy: Bool = false) async throws -> [JSON] {
        let when = NJTParse.plannerMoment(moment)
        let payload = try await reply(query: NJTQueries.tripPlanner, variables: [
            "origin": .string(origin),
            "destination": .string(destination),
            "timeOption": .string(arriveBy ? "A" : "D"),
            "date": .string(when.date),
            "time": .string(when.time),
            "accessible": .bool(false),
            "travelMode": .string("CTR"),
            "maxWalkingDistance": .string("1.00"),
            "minimizeTime": .string("T"),
        ])
        if NJTParse.isNoTripsReply(payload) { return [] }
        let data = try Self.data(of: payload)
        // "No trips" only ever comes as the error reply above; a schedule that is
        // missing or not a list is a broken answer, not an empty one.
        guard let itineraries = data["getTripPlannerSchedule"]?.arrayValue else { throw NJTError.missingData }
        return itineraries
    }

    /// Planner lookups spread over the next few hours (four for the app, see
    /// `NJTQueries.plannerOffsetsMinutes`), with a record of which ones failed,
    /// plus one per train in `seeds`, all at once. A seed that fails only
    /// costs its train: the window still stands on the clock lookups.
    public func plannerWindow(
        origin: String,
        destination: String,
        offsets: [Int] = NJTQueries.plannerOffsetsMinutes,
        seeds: [PlannerSeed] = []
    ) async -> PlannerWindow {
        let base = clock()
        // Indexes below `offsets.count` are the clock lookups, then the seeds.
        let results = await withTaskGroup(of: (Int, Result<[JSON], Error>).self) { group -> [Int: Result<[JSON], Error>] in
            for (index, minutes) in offsets.enumerated() {
                group.addTask {
                    let at = base.addingTimeInterval(Double(minutes) * 60)
                    do {
                        return (index, .success(try await fetchTripPlanner(origin: origin, destination: destination, at: at)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for (number, seed) in seeds.enumerated() {
                group.addTask {
                    do {
                        return (offsets.count + number, .success(try await seedLookup(origin: origin, destination: destination, seed: seed)))
                    } catch {
                        return (offsets.count + number, .failure(error))
                    }
                }
            }
            var collected: [Int: Result<[JSON], Error>] = [:]
            for await (index, result) in group { collected[index] = result }
            return collected
        }
        var window = PlannerWindow(origin: origin, destination: destination, lookups: offsets.count)
        for index in offsets.indices {
            switch results[index] {
            case .success(let list)?:
                window.itineraries.append(contentsOf: list)
            case .failure(let error)?:
                window.failedLookups.append(index)
                if window.reason == nil {
                    window.reason = (error as? LocalizedError)?.errorDescription ?? "unavailable"
                }
            case nil:
                window.failedLookups.append(index)
            }
        }
        window.seedLookups = seeds.count
        for number in seeds.indices {
            if case .success(let list)? = results[offsets.count + number] {
                window.itineraries.append(contentsOf: list)
            } else {
                window.failedSeeds += 1
            }
        }
        return window
    }

    /// One per-train lookup, answered from `plannerCache` while fresh.
    func seedLookup(origin: String, destination: String, seed: PlannerSeed) async throws -> [JSON] {
        let when = NJTParse.plannerMoment(seed.at)
        let key = "\(origin)|\(destination)|\(seed.arriveBy ? "A" : "D")|\(when.date) \(when.time)"
        if let cached = plannerCache.itineraries(for: key, now: clock()) { return cached }
        let list = try await fetchTripPlanner(origin: origin, destination: destination, at: seed.at, arriveBy: seed.arriveBy)
        plannerCache.store(list, for: key, now: clock())
        return list
    }

    /// The home station's own trains this way, from its departure board, as
    /// planner lookups: each train leaving home for the city on the way in,
    /// "leave at" its departure; each train coming out of the city on the
    /// way home, "arrive by" its time at home, which NJ Transit answers with
    /// the latest way to catch it. The planner gives three itineraries per
    /// lookup, ranked by arrival, so lookups spaced by the clock skip trains
    /// and one per train doesn't. Soonest first, at most `limit`, from now to
    /// `horizon` ahead; none for a trip that doesn't start or end at home.
    public static func plannerSeeds(for pair: ODPair, homeBoard: [String: BoardEntry], now: Date, horizon: TimeInterval, limit: Int) -> [PlannerSeed] {
        let home = UserConfig.homeId
        guard limit > 0, pair.fromId == home || pair.toId == home else { return [] }
        let leavingHome = pair.fromId == home
        var times = Set<Date>()
        for entry in homeBoard.values where NJTParse.isTowardCity(entry.destination) == leavingHome {
            guard let raw = entry.departureRaw, let time = NJTParse.rawToDate(raw, baseNow: now) else { continue }
            if time >= now.addingTimeInterval(-Status.departureGrace), time <= now.addingTimeInterval(horizon) {
                times.insert(time)
            }
        }
        return times.sorted().prefix(limit).map { PlannerSeed(at: $0, arriveBy: !leavingHome) }
    }

    /// The itineraries from `plannerWindow`, for callers that only need them.
    public func fetchTripPlannerWindow(origin: String, destination: String) async -> [JSON] {
        await plannerWindow(origin: origin, destination: destination).itineraries
    }

    // MARK: Boards and trips

    /// Board index per station id; a failed board is recorded and left empty.
    private func boards(for stationIds: [String]) async -> (indexes: [String: [String: BoardEntry]], failures: [String]) {
        await withTaskGroup(of: (String, [String: BoardEntry], String?).self) { group -> (indexes: [String: [String: BoardEntry]], failures: [String]) in
            for id in stationIds {
                group.addTask {
                    guard let station = Stations.station(id) else { return (id, [:], nil) }
                    do {
                        let items = try await fetchDepartureBoard(station.name)
                        return (id, NJTParse.buildBoardIndex(items), nil)
                    } catch {
                        let reason = (error as? LocalizedError)?.errorDescription ?? "unavailable"
                        return (id, [:], "\(station.name) board: \(reason)")
                    }
                }
            }
            var indexes: [String: [String: BoardEntry]] = [:]
            var failuresById: [String: String] = [:]
            for await (id, index, failure) in group {
                indexes[id] = index
                if let failure { failuresById[id] = failure }
            }
            // Keep failures in station order, like v4's sequential record.
            let failures = stationIds.compactMap { failuresById[$0] }
            return (indexes, failures)
        }
    }

    /// Trips per pair, in pair order, plus the failure message of each pair
    /// whose planner window failed (see `PlannerWindow.failed`). Pairs in
    /// `required` (all when nil) get `NJTQueries.seedsForShownDirection`
    /// per-train lookups, the rest `otherSeeds`.
    private func trips(
        for pairs: [ODPair],
        boards: [String: [String: BoardEntry]],
        offsets: [Int],
        required: Set<String>?,
        otherSeeds: Int
    ) async -> (groups: [[Trip]], failures: [Int: String]) {
        let baseNow = clock()
        let homeBoard = boards[UserConfig.homeId] ?? [:]
        // Seeds reach as far as the clock lookups start, and at least an hour.
        let horizon = TimeInterval(max(offsets.max() ?? 0, 60) * 60)
        let results = await withTaskGroup(of: (Int, [Trip], String?).self) { group -> [Int: ([Trip], String?)] in
            for (index, pair) in pairs.enumerated() {
                let shown = required?.contains(pair.key) ?? true
                let seeds = Self.plannerSeeds(
                    for: pair,
                    homeBoard: homeBoard,
                    now: baseNow,
                    horizon: horizon,
                    limit: shown ? NJTQueries.seedsForShownDirection : otherSeeds
                )
                group.addTask {
                    guard let from = Stations.station(pair.fromId), let to = Stations.station(pair.toId) else {
                        return (index, [], nil)
                    }
                    let window = await plannerWindow(origin: from.plannerName, destination: to.plannerName, offsets: offsets, seeds: seeds)
                    let planned = NJTParse.normalizeItineraries(
                        window.itineraries,
                        fromId: pair.fromId,
                        toId: pair.toId,
                        boardIndex: boards[pair.fromId] ?? [:],
                        baseNow: baseNow
                    )
                    // The boards correct the timetable, except when the timetable
                    // says nothing runs: a board's times carry no date, and on a
                    // day without service it could be showing another day's.
                    let timetableSaysNone = !window.failed && window.itineraries.isEmpty
                    let trips = timetableSaysNone ? planned : BoardTruth.reconcile(planned, pair: pair, boards: boards, fetchedAt: baseNow)
                    // Leaving home, the home station's board says which trains
                    // go, so a planner outage only costs their arrival times.
                    let answeredByBoard = pair.fromId == UserConfig.homeId && BoardTruth.homeBoardAnswers(homeBoard, fetchedAt: baseNow)
                    return (index, trips, window.failed && !answeredByBoard ? window.failureMessage : nil)
                }
            }
            var collected: [Int: ([Trip], String?)] = [:]
            for await (index, trips, failure) in group { collected[index] = (trips, failure) }
            return collected
        }
        let groups = pairs.indices.map { results[$0]?.0 ?? [] }
        var failures: [Int: String] = [:]
        for index in pairs.indices {
            if let failure = results[index]?.1 { failures[index] = failure }
        }
        return (groups, failures)
    }

    /// Every direction's upcoming trips, with tracks and status from each
    /// origin's departure board. Directions that come back empty are retried
    /// from the nearest station with service (the Montclair Branch runs no
    /// weekend trains north of Bay Street).
    ///
    /// A direction whose planner window failed (see `PlannerWindow.failed`),
    /// or whose nearby-station retry failed, has no trustworthy answer: an
    /// empty direction must mean "no trains", never "NJ Transit didn't
    /// answer". What happens then depends on `required`:
    /// - A required direction (the one the board is showing) fails the whole
    ///   refresh, so the board keeps its last data and turns STALE instead of
    ///   claiming there is no service. nil means every direction is required.
    /// - Any other direction keeps its trips from `previous`, marked with when
    ///   they were fetched (`Payload.carriedOver`), so they turn stale on their
    ///   own clock; with nothing to carry over it is marked unanswered, which
    ///   the board never reads as "no trains".
    ///
    /// Also throws when nothing at all came back and something failed. A
    /// failed departure board only costs tracks and status, so it still
    /// yields a (partial) payload.
    public func fetchLivePayload(
        pairs: [ODPair] = Alternates.defaultPairs(),
        plannerOffsets: [Int] = NJTQueries.plannerOffsetsMinutes,
        required: Set<String>? = nil,
        previous: Payload? = nil
    ) async throws -> Payload {
        func isRequired(_ pair: ODPair) -> Bool { required?.contains(pair.key) ?? true }

        var stationIds: [String] = []
        for pair in pairs where !stationIds.contains(pair.fromId) {
            stationIds.append(pair.fromId)
        }

        var failures: [String] = []
        func record(_ message: String) {
            if !message.isEmpty, !failures.contains(message), failures.count < 6 {
                failures.append(message)
            }
        }

        let primary = await boards(for: stationIds)
        primary.failures.forEach(record)
        var boardIndexes = primary.indexes

        // With nothing from an earlier refresh (the app just opened), only the
        // directions in `required` get per-train lookups, so the board on screen
        // loads as fast as before; the next refresh adds the others' from cache.
        let otherSeeds = previous == nil ? 0 : NJTQueries.seedsForOtherDirection
        let primaryTrips = await trips(for: pairs, boards: boardIndexes, offsets: plannerOffsets, required: required, otherSeeds: otherSeeds)
        /// Why each direction (by index into `pairs`) has no trustworthy answer.
        var unreliable: [Int: String] = primaryTrips.failures
        func throwIfARequiredDirectionFailed() throws {
            let blocking = pairs.indices.filter { unreliable[$0] != nil && isRequired(pairs[$0]) }
            if !blocking.isEmpty {
                throw NJTError.feed((failures + blocking.compactMap { unreliable[$0] }).joined(separator: " | "))
            }
        }
        try throwIfARequiredDirectionFailed()

        // Directions that answered with no trains are retried from the
        // nearest station with service; the retry belongs to its direction.
        var extraTrips: [Int: [Trip]] = [:]
        let emptyKeys = Set(pairs.indices.filter { unreliable[$0] == nil && primaryTrips.groups[$0].isEmpty }.map { pairs[$0].key })
        let extraPairs = Alternates.substitutePairs(
            pairs,
            emptyPairKeys: emptyKeys,
            homeId: UserConfig.homeId,
            fallbackIds: UserConfig.fallbackOriginIds
        )
        if !extraPairs.isEmpty {
            var extraStations: [String] = []
            for pair in extraPairs where !extraStations.contains(pair.fromId) {
                extraStations.append(pair.fromId)
            }
            let extra = await boards(for: extraStations)
            for (id, index) in extra.indexes { boardIndexes[id] = index }
            let retried = await trips(for: extraPairs, boards: boardIndexes, offsets: plannerOffsets, required: required, otherSeeds: otherSeeds)
            for (index, extraPair) in extraPairs.enumerated() {
                guard let owner = pairs.indices.first(where: { Self.alternateKeys(for: pairs[$0]).contains(extraPair.key) && emptyKeys.contains(pairs[$0].key) }) else { continue }
                if let failure = retried.failures[index] {
                    // The nearby station's list is what the board offers
                    // instead, so it must not silently vanish either.
                    if unreliable[owner] == nil { unreliable[owner] = failure }
                } else {
                    extraTrips[owner, default: []].append(contentsOf: retried.groups[index])
                }
            }
            try throwIfARequiredDirectionFailed()
        }

        // Answered directions first, in pair order, then their nearby-station
        // trips; a direction without an answer keeps what it had.
        var allTrips: [Trip] = []
        var carried: [String: Date] = [:]
        var unanswered: [String] = []
        var kept: [String] = []
        for index in pairs.indices where unreliable[index] == nil {
            allTrips.append(contentsOf: primaryTrips.groups[index])
        }
        for index in pairs.indices where unreliable[index] == nil {
            allTrips.append(contentsOf: extraTrips[index] ?? [])
        }
        for index in pairs.indices {
            guard let failure = unreliable[index] else { continue }
            kept.append(failure)
            let pair = pairs[index]
            if let previous, previous.source.kind == .live, let fetched = previous.updatedAt(forPair: pair.key) {
                let keys = Self.alternateKeys(for: pair).union([pair.key])
                allTrips.append(contentsOf: previous.trips.filter { keys.contains("\($0.fromId)|\($0.toId)") })
                carried[pair.key] = fetched
            } else {
                unanswered.append(pair.key)
            }
        }
        if allTrips.isEmpty && !failures.isEmpty {
            throw NJTError.feed(failures.joined(separator: " | "))
        }

        var notes: [String] = []
        if !failures.isEmpty { notes.append("some boards unavailable: \(failures.joined(separator: ", "))") }
        if !kept.isEmpty { notes.append("earlier trips kept for \(kept.joined(separator: ", "))") }
        return Payload(
            generatedAt: clock(),
            source: PayloadSource(
                kind: .live,
                detail: notes.isEmpty
                    ? "Live NJ Transit rail planner with origin-board tracks."
                    : "Live NJ Transit feed (partial, \(notes.joined(separator: "; ")))."
            ),
            trips: allTrips,
            carriedOver: carried.isEmpty ? nil : carried,
            unanswered: unanswered.isEmpty ? nil : unanswered
        )
    }

    /// The nearby-station lookups that stand in for `pair` when it has no trains.
    static func alternateKeys(for pair: ODPair) -> Set<String> {
        Set(Alternates.alternateRoutes(
            fromId: pair.fromId,
            toId: pair.toId,
            homeId: UserConfig.homeId,
            fallbackIds: UserConfig.fallbackOriginIds
        ).map(\.key))
    }

    // MARK: Stop lists

    /// Full stop list for one train run. Empty (not an error) when NJT has no
    /// data for the id.
    public func fetchTrainStops(_ trainId: String) async throws -> [TrainStop] {
        let data = try await post(query: NJTQueries.trainStops, variables: ["train": .string(trainId)])
        return NJTParse.parseStops(data["getTrainStopList"]?.arrayValue ?? [], baseNow: clock())
    }

    /// Stop lists for several trains at once (validated and capped at eight).
    /// A train whose list fails or comes back empty is omitted, so merging the
    /// result can only add stop data, never blank out good data.
    public func fetchTrainRuns(_ trainIds: [String]) async -> Runs {
        let ids = NJTParse.parseTrainIds(trainIds.joined(separator: ","))
        return await withTaskGroup(of: (String, [TrainStop]?).self) { group -> Runs in
            for id in ids {
                group.addTask {
                    (id, try? await fetchTrainStops(id))
                }
            }
            var runs: Runs = [:]
            for await (id, stops) in group {
                if let stops, !stops.isEmpty { runs[id] = stops }
            }
            return runs
        }
    }
}

/// One direction's planner lookups (see `NJTClient.plannerWindow`).
public struct PlannerWindow: Sendable {
    public var origin: String
    public var destination: String
    /// How many lookups were made.
    public var lookups: Int
    /// Every itinerary returned, in lookup order.
    public var itineraries: [JSON] = []
    /// Indexes (into the offsets) of the lookups that failed.
    public var failedLookups: [Int] = []
    /// NJ Transit's reason for the first failure.
    public var reason: String?
    /// How many per-train lookups were made (see `PlannerSeed`), and how many
    /// of them failed. Those never fail the window.
    public var seedLookups = 0
    public var failedSeeds = 0

    public init(origin: String, destination: String, lookups: Int) {
        self.origin = origin
        self.destination = destination
        self.lookups = lookups
    }

    /// The window can't be trusted when every lookup failed, or when the
    /// first one did and no per-train lookup answered: the first covers the
    /// next trains (as do the per-train ones), so without either the board
    /// would feature a train an hour or more away as "next". Later lookups
    /// failing only shortens how far ahead the board sees.
    public var failed: Bool {
        guard lookups > 0 else { return false }
        let seedsAnswered = seedLookups > failedSeeds
        if failedLookups.count >= lookups && !seedsAnswered { return true }
        return failedLookups.contains(0) && !seedsAnswered
    }

    /// "Watchung Avenue Station to Hoboken Terminal planner: NJT public feed HTTP 500"
    public var failureMessage: String {
        "\(origin) to \(destination) planner: \(reason ?? "unavailable")"
    }
}

/// A planner lookup pinned to one train at the home station (see
/// `NJTClient.plannerSeeds`): leave at its departure, or arrive by its time.
public struct PlannerSeed: Equatable, Hashable, Sendable {
    public var at: Date
    public var arriveBy: Bool

    public init(at: Date, arriveBy: Bool) {
        self.at = at
        self.arriveBy = arriveBy
    }
}

/// Answers to per-train planner lookups, each kept for `lifetime`. A seed
/// sits at a train's own time, so the same lookups recur refresh after
/// refresh while that train is on the board; reusing them keeps a refresh's
/// load on NJ Transit near what the four clock lookups alone cost. Those move
/// with the clock and are never cached. Only answers are kept, not failures.
public final class PlannerCache: @unchecked Sendable {
    public let lifetime: TimeInterval
    private let lock = NSLock()
    private var entries: [String: (storedAt: Date, itineraries: [JSON])] = [:]

    public init(lifetime: TimeInterval = NJTQueries.seedCacheLifetime) {
        self.lifetime = lifetime
    }

    /// The stored answer for `key`, unless it is older than `lifetime`.
    public func itineraries(for key: String, now: Date) -> [JSON]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        let age = now.timeIntervalSince(entry.storedAt)
        return age >= 0 && age < lifetime ? entry.itineraries : nil
    }

    /// Store an answer, dropping any that have expired.
    public func store(_ itineraries: [JSON], for key: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { now.timeIntervalSince($0.value.storedAt) < lifetime }
        entries[key] = (storedAt: now, itineraries: itineraries)
    }

    /// How many answers are stored, expired or not.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
