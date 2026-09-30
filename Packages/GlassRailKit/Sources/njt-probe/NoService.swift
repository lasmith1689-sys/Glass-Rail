import Foundation
import GlassRailKit

// What NJ Transit's trip planner answers for a window with no trains: Watchung
// Avenue has no weekend service (the Montclair Branch stops at Bay Street) and
// little or none in the small hours. The planner takes a date, so a weekday run
// can still ask about next Saturday and about 3 AM. Each raw reply is saved
// (the CI job publishes them to the ci-njt-probe branch), then the whole
// payload is built as the app would build it at that moment.

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

func probeNoService() async {
    let now = Date()
    let saturday = upcoming(weekdays: [7], hour: 10, after: now)
    let smallHours = upcoming(weekdays: [2, 3, 4, 5, 6], hour: 3, after: now)
    print("No-service probe at \(ISOTime.string(from: now)): Saturday window \(label(saturday)), small-hours window \(label(smallHours))")

    let watchung = Stations.watchung
    let hoboken = Stations.station("hoboken")!
    let penn = Stations.station("penn")!
    let bay = Stations.station("baystreet")!
    let lookups: [(name: String, at: Date, from: Station, to: Station)] = [
        ("saturday-watchung-hoboken", saturday, watchung, hoboken),
        ("saturday-hoboken-watchung", saturday, hoboken, watchung),
        ("saturday-watchung-penn", saturday, watchung, penn),
        ("saturday-penn-watchung", saturday, penn, watchung),
        ("saturday-baystreet-hoboken", saturday, bay, hoboken),
        ("saturday-hoboken-baystreet", saturday, hoboken, bay),
        ("3am-watchung-hoboken", smallHours, watchung, hoboken),
        ("3am-hoboken-watchung", smallHours, hoboken, watchung),
        ("3am-watchung-penn", smallHours, watchung, penn),
        ("3am-penn-watchung", smallHours, penn, watchung),
    ]

    var index: [[String: Any]] = []
    var lines: [String: [String]] = [:]
    for lookup in lookups {
        let recorder = Recorder()
        let at = lookup.at
        let client = NJTClient(transport: recorder, clock: { at })
        var outcome: String
        var summaries: [String] = []
        do {
            let list = try await client.fetchTripPlanner(origin: lookup.from.plannerName, destination: lookup.to.plannerName, at: lookup.at)
            outcome = "answered, \(list.count) itineraries"
            summaries = list.prefix(3).map(legsSummary)
        } catch {
            outcome = "threw \(error) (\(error.localizedDescription))"
        }
        let reply = recorder.replies.last
        if let reply { save("\(lookup.name).json", reply.response.body) }
        let moment = NJTParse.plannerMoment(lookup.at)
        index.append([
            "name": lookup.name,
            "origin": lookup.from.plannerName,
            "destination": lookup.to.plannerName,
            "date": moment.date,
            "time": moment.time,
            "status": reply?.response.status ?? 0,
            "outcome": outcome,
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
        }
        notice("app refresh at \(name) \(label(at))", report.joined(separator: "\n"))
        print("\(name): " + report.joined(separator: " / "))
    }
}
