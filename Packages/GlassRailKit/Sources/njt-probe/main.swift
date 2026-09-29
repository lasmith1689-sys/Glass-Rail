// Live check of NJ Transit's GraphQL feed, run by CI on a GitHub runner (never
// on a personal machine). Prints the shape of each reply and what the parser
// makes of it, and writes the raw replies to the output directory.
//
//   swift run --package-path Packages/GlassRailKit njt-probe <out-dir>
import Foundation
import GlassRailKit

final class Recorder: NJTTransport, @unchecked Sendable {
    let inner = URLSessionTransport(timeout: 20)
    private let lock = NSLock()
    private(set) var replies: [(request: Data, response: NJTHTTPResponse)] = []

    func send(_ body: Data) async throws -> NJTHTTPResponse {
        let response = try await inner.send(body)
        lock.lock()
        replies.append((body, response))
        lock.unlock()
        return response
    }
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "njt-probe-out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// A GitHub annotation (single line; newlines escaped as GitHub expects).
func notice(_ title: String, _ message: String) {
    let escaped = message
        .replacingOccurrences(of: "%", with: "%25")
        .replacingOccurrences(of: "\r", with: "%0D")
        .replacingOccurrences(of: "\n", with: "%0A")
    print("::notice title=\(title)::\(escaped)")
}

func compact(_ data: Data, limit: Int = 2800) -> String {
    let text: String
    if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
       let again = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) {
        text = String(decoding: again, as: UTF8.self)
    } else {
        text = String(decoding: data, as: UTF8.self)
    }
    return text.count > limit ? String(text.prefix(limit)) + "…(\(text.count) chars)" : text
}

func save(_ name: String, _ data: Data) {
    try? data.write(to: outDir.appendingPathComponent(name))
}

let recorder = Recorder()
let client = NJTClient(transport: recorder)
let started = Date()
print("NJ Transit probe at \(ISOTime.string(from: started)) (\(Format.time(started)) Eastern)")

// 1. One departure board, raw.
do {
    let items = try await client.fetchDepartureBoard("Watchung Avenue")
    if let last = recorder.replies.last {
        save("board-watchung.json", last.response.body)
        notice("board Watchung Avenue: HTTP \(last.response.status), \(items.count) items", compact(last.response.body))
    }
} catch {
    let status = recorder.replies.last.map { "HTTP \($0.response.status)" } ?? "no reply"
    let body = recorder.replies.last.map { compact($0.response.body, limit: 600) } ?? ""
    notice("board Watchung Avenue FAILED", "\(status): \(error.localizedDescription) \(body)")
}

// 2. One planner lookup, raw.
do {
    let itineraries = try await client.fetchTripPlanner(origin: "Watchung Avenue Station", destination: "Hoboken Terminal", at: Date())
    if let last = recorder.replies.last {
        save("planner-watchung-hoboken.json", last.response.body)
        notice("planner Watchung to Hoboken: HTTP \(last.response.status), \(itineraries.count) itineraries", compact(last.response.body))
    }
} catch {
    notice("planner Watchung to Hoboken FAILED", error.localizedDescription)
}

// 3. The whole payload, as the app builds it.
var firstTrain: String?
do {
    let t0 = Date()
    let payload = try await client.fetchLivePayload()
    let seconds = Date().timeIntervalSince(t0)
    var lines: [String] = ["\(payload.trips.count) trips in \(String(format: "%.1f", seconds)) s. \(payload.source.detail)"]
    for pair in Alternates.defaultPairs() + [ODPair(fromId: "baystreet", toId: "hoboken")] {
        let trips = payload.trips.filter { $0.fromId == pair.fromId && $0.toId == pair.toId }
        let listed = trips.prefix(4).map { trip in
            "\(trip.trainId ?? "?") \(Format.time(trip.departure))\(trip.track.map { " Tk \($0)" } ?? "")\(trip.status.map { " \($0.rawValue)" } ?? "")\(trip.transferCount > 0 ? " via \(trip.transferAt.joined(separator: "/"))" : "")"
        }
        lines.append("\(pair.key): \(trips.count) [\(listed.joined(separator: ", "))]")
    }
    firstTrain = payload.trips.first { $0.fromId == "watchung" }?.trainId ?? payload.trips.first?.trainId
    save("payload.json", (try? GlassRailJSON.encoder().encode(payload)) ?? Data())
    notice("live payload", lines.joined(separator: "\n"))
} catch {
    notice("live payload FAILED", error.localizedDescription)
}

// 4. One stop list, raw and parsed.
if let train = firstTrain {
    do {
        let stops = try await client.fetchTrainStops(train)
        if let last = recorder.replies.last {
            save("stops-\(train).json", last.response.body)
            notice("stops \(train): HTTP \(last.response.status), \(stops.count) stops", compact(last.response.body))
        }
        let parsed = stops.map { "\($0.name) \($0.time.map(Format.time) ?? "?")\($0.departed ? " departed" : "")\($0.note.map { " (\($0))" } ?? "")" }
        notice("stops \(train) parsed", parsed.joined(separator: "\n"))
    } catch {
        notice("stops \(train) FAILED", error.localizedDescription)
    }
}

print("Probe finished in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, \(recorder.replies.count) requests.")
