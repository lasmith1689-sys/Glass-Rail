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

    public init(transport: any NJTTransport = URLSessionTransport(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.clock = clock
    }

    // MARK: GraphQL

    /// POST a query and return its `data` object, throwing NJT's own error text.
    public func post(query: String, variables: [String: GQLValue]) async throws -> JSON {
        let object: [String: Any] = [
            "query": query,
            "variables": variables.mapValues { $0.jsonObject },
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [])
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

    public func fetchTripPlanner(origin: String, destination: String, at moment: Date) async throws -> [JSON] {
        let when = NJTParse.plannerMoment(moment)
        let data = try await post(query: NJTQueries.tripPlanner, variables: [
            "origin": .string(origin),
            "destination": .string(destination),
            "timeOption": .string("D"),
            "date": .string(when.date),
            "time": .string(when.time),
            "accessible": .bool(false),
            "travelMode": .string("CTR"),
            "maxWalkingDistance": .string("1.00"),
            "minimizeTime": .string("T"),
        ])
        return data["getTripPlannerSchedule"]?.arrayValue ?? []
    }

    /// Planner lookups spread over the next few hours (four for the app, see
    /// `NJTQueries.plannerOffsetsMinutes`), with a record of which ones failed.
    public func plannerWindow(origin: String, destination: String, offsets: [Int] = NJTQueries.plannerOffsetsMinutes) async -> PlannerWindow {
        let base = clock()
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
        return window
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
    /// whose planner window failed (see `PlannerWindow.failed`).
    private func trips(for pairs: [ODPair], boards: [String: [String: BoardEntry]], offsets: [Int]) async -> (groups: [[Trip]], failures: [Int: String]) {
        let baseNow = clock()
        let results = await withTaskGroup(of: (Int, [Trip], String?).self) { group -> [Int: ([Trip], String?)] in
            for (index, pair) in pairs.enumerated() {
                group.addTask {
                    guard let from = Stations.station(pair.fromId), let to = Stations.station(pair.toId) else {
                        return (index, [], nil)
                    }
                    let window = await plannerWindow(origin: from.plannerName, destination: to.plannerName, offsets: offsets)
                    let trips = NJTParse.normalizeItineraries(
                        window.itineraries,
                        fromId: pair.fromId,
                        toId: pair.toId,
                        boardIndex: boards[pair.fromId] ?? [:],
                        baseNow: baseNow
                    )
                    return (index, trips, window.failed ? window.failureMessage : nil)
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
    /// Throws when nothing at all came back and something failed, and when
    /// any direction's planner window failed: an empty direction must mean
    /// "no trains", never "NJ Transit didn't answer", so an outage makes the
    /// board keep its last data (and turn STALE) instead of claiming there is
    /// no service. A failed departure board only costs tracks and status, so
    /// it still yields a (partial) payload.
    public func fetchLivePayload(
        pairs: [ODPair] = Alternates.defaultPairs(),
        plannerOffsets: [Int] = NJTQueries.plannerOffsetsMinutes
    ) async throws -> Payload {
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

        let primaryTrips = await trips(for: pairs, boards: boardIndexes, offsets: plannerOffsets)
        let tripGroups = primaryTrips.groups
        var allTrips = tripGroups.flatMap { $0 }
        let plannerFailures = pairs.indices.compactMap { primaryTrips.failures[$0] }
        if !plannerFailures.isEmpty {
            throw NJTError.feed((failures + plannerFailures).joined(separator: " | "))
        }

        let emptyKeys = Set(pairs.indices.filter { tripGroups[$0].isEmpty }.map { pairs[$0].key })
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
            let extraTrips = await trips(for: extraPairs, boards: boardIndexes, offsets: plannerOffsets)
            allTrips.append(contentsOf: extraTrips.groups.flatMap { $0 })
            // The nearby station's list is what the board offers instead, so
            // it must not silently vanish either.
            let extraFailures = extraPairs.indices.compactMap { extraTrips.failures[$0] }
            if !extraFailures.isEmpty {
                throw NJTError.feed((failures + extraFailures).joined(separator: " | "))
            }
        }
        if allTrips.isEmpty && !failures.isEmpty {
            throw NJTError.feed(failures.joined(separator: " | "))
        }

        return Payload(
            generatedAt: clock(),
            source: PayloadSource(
                kind: .live,
                detail: failures.isEmpty
                    ? "Live NJ Transit rail planner with origin-board tracks."
                    : "Live NJ Transit feed (partial, some boards unavailable: \(failures.joined(separator: ", ")))."
            ),
            trips: allTrips
        )
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

    public init(origin: String, destination: String, lookups: Int) {
        self.origin = origin
        self.destination = destination
        self.lookups = lookups
    }

    /// The window can't be trusted when every lookup failed, or when the
    /// first one did: that lookup covers the next trains, so without it the
    /// board would feature a train an hour or more away as "next".
    /// Later lookups failing only shortens how far ahead the board sees.
    public var failed: Bool {
        guard lookups > 0 else { return false }
        return failedLookups.count >= lookups || failedLookups.contains(0)
    }

    /// "Watchung Avenue Station to Hoboken Terminal planner: NJT public feed HTTP 500"
    public var failureMessage: String {
        "\(origin) to \(destination) planner: \(reason ?? "unavailable")"
    }
}
