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

    /// Four planner lookups spread over the next few hours. A failed lookup
    /// contributes nothing rather than failing the window.
    public func fetchTripPlannerWindow(origin: String, destination: String) async -> [JSON] {
        let base = clock()
        let offsets = NJTQueries.plannerOffsetsMinutes
        let results = await withTaskGroup(of: (Int, [JSON]).self) { group -> [Int: [JSON]] in
            for (index, minutes) in offsets.enumerated() {
                group.addTask {
                    let at = base.addingTimeInterval(Double(minutes) * 60)
                    let list = (try? await fetchTripPlanner(origin: origin, destination: destination, at: at)) ?? []
                    return (index, list)
                }
            }
            var collected: [Int: [JSON]] = [:]
            for await (index, list) in group { collected[index] = list }
            return collected
        }
        return offsets.indices.flatMap { results[$0] ?? [] }
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

    private func trips(for pairs: [ODPair], boards: [String: [String: BoardEntry]]) async -> [[Trip]] {
        let baseNow = clock()
        let groups = await withTaskGroup(of: (Int, [Trip]).self) { group -> [Int: [Trip]] in
            for (index, pair) in pairs.enumerated() {
                group.addTask {
                    guard let from = Stations.station(pair.fromId), let to = Stations.station(pair.toId) else {
                        return (index, [])
                    }
                    let itineraries = await fetchTripPlannerWindow(origin: from.plannerName, destination: to.plannerName)
                    let trips = NJTParse.normalizeItineraries(
                        itineraries,
                        fromId: pair.fromId,
                        toId: pair.toId,
                        boardIndex: boards[pair.fromId] ?? [:],
                        baseNow: baseNow
                    )
                    return (index, trips)
                }
            }
            var collected: [Int: [Trip]] = [:]
            for await (index, trips) in group { collected[index] = trips }
            return collected
        }
        return pairs.indices.map { groups[$0] ?? [] }
    }

    /// Every direction's upcoming trips, with tracks and status from each
    /// origin's departure board. Directions that come back empty are retried
    /// from the nearest station with service (the Montclair Branch runs no
    /// weekend trains north of Bay Street). Throws only when nothing at all
    /// came back and something failed.
    public func fetchLivePayload(pairs: [ODPair] = Alternates.defaultPairs()) async throws -> Payload {
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

        let tripGroups = await trips(for: pairs, boards: boardIndexes)
        var allTrips = tripGroups.flatMap { $0 }

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
            let extraGroups = await trips(for: extraPairs, boards: boardIndexes)
            allTrips.append(contentsOf: extraGroups.flatMap { $0 })
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
