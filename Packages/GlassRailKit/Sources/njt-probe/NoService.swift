import Foundation
import GlassRailKit

// What NJ Transit's trip planner answers for a window with no trains: Watchung
// Avenue has no weekend service (the Montclair Branch stops at Bay Street) and
// little or none in the small hours. The planner takes a date, so a weekday run
// can still ask about next Saturday and about 3 AM. Each raw reply is saved
// (the CI job publishes them to the ci-njt-probe branch), then the whole
// payload is built as the app would build it at that moment and checked:
// Saturday must read "No trains" with Bay Street instead, and 3 AM must list
// the first morning trains. A mismatch fails the step (the job is
// informational, so it never blocks the rest of CI).

enum Expect { case noTrips, trains }

/// The first day after `after` (Eastern) whose weekday is in `weekdays`
/// (1 = Sunday ... 7 = Saturday), at `hour`:00 Eastern.
func upcoming(weekdays: Set<Int>, hour: Int, after: Date) -> Date {
    let today = Eastern.ymd(of: after)
    let noon = Eastern.date(year: today.year, month: today.month, day: today.day, hour: 12, minute: 0) ?? after
    for days in 1...8 {
        let day = noon.addingTimeInterval(Double(days) * 24 * 3600)
        guard weekdays.contains(Eastern.calendar.component(.weekday, from: day)) else { continue }
        let ymd = Eastern.ymd(of: day)
        if let moment = Eastern.date(year: ymd.year, month: ymd.month, day: ymd.day, hour: hour, minute: 0) {
            return moment
        }
    }
    return after
}

/// "Sat 10/03/2026 10:00 AM"
func label(_ date: Date) -> String {
    let moment = NJTParse.plannerMoment(date)
    let weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][Eastern.calendar.component(.weekday, from: date) - 1]
    return "\(weekday) \(moment.date) \(moment.time)"
}

/// One itinerary's legs, compactly: "C 6200 WATCHUNG AVENUE 4:48 AM > NEWARK BROAD ST 5:09 AM".
func legsSummary(_ itinerary: JSON) -> String {
    let legs = itinerary["legs"]?.arrayValue ?? []
    let parts = legs.map { leg -> String in
        let type = NJTParse.clean(leg["routeType"])
        let block = NJTParse.clean(leg["block"])
        return "\(type.isEmpty ? "?" : type) \(block.isEmpty ? "-" : block) \(NJTParse.clean(leg["onStopDescription"])) \(NJTParse.clean(leg["onStopTime"])) > \(NJTParse.clean(leg["offStopDescription"])) \(NJTParse.clean(leg["offStopTime"]))"
    }
    return "[\(NJTParse.clean(itinerary["duration"]))] " + parts.joined(separator: " | ")
}

/// Returns false when NJ Transit's replies, or what the app makes of them, are
/// not what the app is built for.
func probeNoService() async -> Bool {
    let now = Date()
    let saturday = upcoming(weekdays: [7], hour: 10, after: now)
    let smallHours = upcoming(weekdays: [2, 3, 4, 5, 6], hour: 3, after: now)
    print("No-service probe at \(ISOTime.string(from: now)): Saturday window \(label(saturday)), small-hours window \(label(smallHours))")

    let watchung = Stations.watchung
    let hoboken = Stations.station("hoboken")!
    let penn = Stations.station("penn")!
    let bay = Stations.station("baystreet")!
    // Not a station: shows whether a bad name gets the same "no trips" words.
    let nowhere = Station(id: "nowhere", name: "Nowhere", plannerName: "Nowhere Station", shortLabel: "Nowhere")
    // What the app is built on: no weekend trains at Watchung Avenue (NJ
    // Transit's no-trips reply, read as no itineraries), weekend trains at Bay
    // Street, and the first morning trains at 3 AM. nil: just recorded.
    let lookups: [(name: String, at: Date, from: Station, to: Station, expect: Expect?)] = [
        ("saturday-watchung-hoboken", saturday, watchung, hoboken, .noTrips),
        ("saturday-hoboken-watchung", saturday, hoboken, watchung, .noTrips),
        ("saturday-watchung-penn", saturday, watchung, penn, .noTrips),
        ("saturday-penn-watchung", saturday, penn, watchung, .noTrips),
        ("saturday-baystreet-hoboken", saturday, bay, hoboken, .trains),
        ("saturday-hoboken-baystreet", saturday, hoboken, bay, .trains),
        ("saturday-baystreet-penn", saturday, bay, penn, nil),
        ("saturday-penn-baystreet", saturday, penn, bay, nil),
        ("3am-watchung-hoboken", smallHours, watchung, hoboken, .trains),
        ("3am-hoboken-watchung", smallHours, hoboken, watchung, .trains),
        ("3am-watchung-penn", smallHours, watchung, penn, .trains),
        ("3am-penn-watchung", smallHours, penn, watchung, .trains),
        ("3am-nowhere-hoboken", smallHours, nowhere, hoboken, nil),
    ]
    var problems: [String] = []

    var index: [[String: Any]] = []
    var lines: [String: [String]] = [:]
    for lookup in lookups {
        let recorder = Recorder()
        let at = lookup.at
        let client = NJTClient(transport: recorder, clock: { at })
        var outcome: String
        var summaries: [String] = []
        var answered: Int?
        do {
            let list = try await client.fetchTripPlanner(origin: lookup.from.plannerName, destination: lookup.to.plannerName, at: lookup.at)
            outcome = "answered, \(list.count) itineraries"
            answered = list.count
            summaries = list.prefix(3).map(legsSummary)
        } catch {
            outcome = "threw \(error) (\(error.localizedDescription))"
        }
        let reply = recorder.replies.last
        if let reply { save("\(lookup.name).json", reply.response.body) }
        let noTrips = reply.flatMap { try? JSON.parse($0.response.body) }.map(NJTParse.isNoTripsReply) ?? false
        if noTrips { outcome += " (NJ Transit's no-trips reply)" }
        switch lookup.expect {
        case .noTrips? where answered != 0 || !noTrips:
            problems.append("\(lookup.name): expected NJ Transit's no-trips reply, read as no itineraries; got HTTP \(reply?.response.status ?? 0), \(outcome)")
        case .trains? where (answered ?? 0) == 0:
            problems.append("\(lookup.name): expected trains; got HTTP \(reply?.response.status ?? 0), \(outcome)")
        default:
            break
        }
        let moment = NJTParse.plannerMoment(lookup.at)
        index.append([
            "name": lookup.name,
            "origin": lookup.from.plannerName,
            "destination": lookup.to.plannerName,
            "date": moment.date,
            "time": moment.time,
            "status": reply?.response.status ?? 0,
            "outcome": outcome,
            "noTripsReply": noTrips,
        ])
        let raw = reply.map { compact($0.response.body, limit: 420) } ?? "no reply"
        let window = lookup.name.hasPrefix("saturday") ? "Saturday \(label(saturday))" : "Small hours \(label(smallHours))"
        var line = "\(lookup.from.shortLabel) > \(lookup.to.shortLabel): HTTP \(reply?.response.status ?? 0), \(outcome). Raw: \(raw)"
        if !summaries.isEmpty { line += " Legs: " + summaries.joined(separator: " // ") }
        lines[window, default: []].append(line)
        print("\(lookup.name): \(line)")
    }
    if let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]) {
        save("no-service-index.json", data)
    }
    // Three lookups per annotation keeps each within GitHub's size limit.
    for (window, list) in lines.sorted(by: { $0.key > $1.key }) {
        for (part, start) in stride(from: 0, to: list.count, by: 3).enumerated() {
            notice("planner, \(window) (\(part + 1))", list[start..<min(start + 3, list.count)].joined(separator: "\n"))
        }
    }

    // The whole refresh as the app makes it at those moments, and what the
    // board then shows each way.
    for (name, at) in [("Saturday", saturday), ("Small hours", smallHours)] {
        let client = NJTClient(transport: Recorder(), clock: { at })
        let weekend = name == "Saturday"
        var report: [String] = []
        do {
            let payload = try await client.fetchLivePayload()
            report.append("\(payload.trips.count) trips. \(payload.source.detail)")
            for destination in UserConfig.destinationIds {
                for commute in [CommuteMode.am, .pm] {
                    let state = BoardEngine.compute(BoardInputs(
                        payload: payload,
                        now: at,
                        destinationId: destination,
                        modeOverride: ModeOverride(mode: commute, at: at)
                    ))
                    var text = "\(state.from.shortLabel) > \(state.to.shortLabel) \(state.feedMode.rawValue): "
                    if state.feedMode != .live {
                        problems.append("\(name) \(state.dirKey): the board would read \(state.feedMode.rawValue), not LIVE")
                    }
                    if weekend && !state.noService {
                        let shown = state.hero?.trip.trainId.map { "train \($0)" } ?? "an empty board"
                        problems.append("\(name) \(state.dirKey): expected No trains from Watchung Ave, got \(shown)")
                    }
                    if weekend && destination == "hoboken" && state.alternate == nil {
                        problems.append("\(name) \(state.dirKey): no Bay Street trains offered instead")
                    }
                    if !weekend && (state.noService || state.hero == nil) {
                        let shown = state.noService ? "No trains" : "nothing listed"
                        problems.append("\(name) \(state.dirKey): expected the first morning train, got \(shown)")
                    }
                    if state.noService {
                        let alternate = state.alternate.map { alt in
                            "\(alt.from.shortLabel) > \(alt.to.shortLabel) " + alt.views.map { "\($0.trip.trainId ?? "?") \(Format.time($0.expectedDeparture))" }.joined(separator: ", ")
                        } ?? "none"
                        text += "NO TRAINS, nearest service \(alternate)"
                    } else if let hero = state.hero {
                        text += "next \(hero.trip.trainId ?? "?") \(Format.time(hero.expectedDeparture)) on \(label(hero.expectedDeparture)), \(state.later.count) later"
                    } else {
                        text += "nothing listed"
                    }
                    report.append(text)
                }
            }
        } catch {
            report.append("refresh FAILED: \(error.localizedDescription)")
            problems.append("\(name): the refresh failed (\(error.localizedDescription))")
        }
        notice("app refresh at \(name) \(label(at))", report.joined(separator: "\n"))
        print("\(name): " + report.joined(separator: " / "))
    }

    if problems.isEmpty {
        notice("No-service check", "NJ Transit answered Watchung Avenue on Saturday with its no-trips reply, the app read it as No trains with Bay Street instead, and 3 AM listed the first morning trains.")
        return true
    }
    let escaped = problems.joined(separator: "\n")
        .replacingOccurrences(of: "%", with: "%25")
        .replacingOccurrences(of: "\n", with: "%0A")
    print("::error title=No-service check::\(escaped)")
    return false
}
