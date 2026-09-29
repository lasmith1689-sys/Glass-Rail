import Foundation

/// One train on a station's departure board, reduced to what the board adds
/// to a planner itinerary (track, anomaly text, status).
public struct BoardEntry: Equatable, Sendable {
    public var track: String?
    public var note: String?
    public var departureRaw: String?
    public var status: TripStatus?

    public init(track: String?, note: String?, departureRaw: String?, status: TripStatus?) {
        self.track = track
        self.note = note
        self.departureRaw = departureRaw
        self.status = status
    }
}

/// Pure parsing of NJ Transit responses: a line-by-line port of the private
/// helpers in lib/njt.ts.
public enum NJTParse {
    // MARK: Text

    /// Strip entities, tags and extra whitespace from an NJT field.
    public static func clean(_ value: JSON?) -> String {
        clean(value.jsString)
    }

    public static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&#9992;", with: "")
        result = RX.replaceAll("<[^>]*>", in: result, with: "")
        result = RX.replaceAll("\\s+", in: result, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `clean(value) || null`
    static func cleanOrNil(_ value: JSON?) -> String? {
        let text = clean(value)
        return text.isEmpty ? nil : text
    }

    // MARK: Status

    /// Structured status from a departure board's status and inline message.
    ///
    /// "in 5 Min" and "All Aboard" count down to the *actual* departure, so
    /// they appear on late trains too and say nothing about punctuality: they
    /// are reported as unknown and the live stop times decide (see Timing).
    public static func parseBoardStatus(_ status: String?, _ inlineMessage: String?) -> TripStatus? {
        let s = clean(status ?? "").lowercased()
        let m = clean(inlineMessage ?? "").lowercased()
        let both = "\(s) \(m)".trimmingCharacters(in: .whitespacesAndNewlines)
        if both.isEmpty { return nil }
        if RX.test("cancel", both) { return .cancelled }
        if RX.test("delay|late", both) { return .delayed }
        if RX.test("^on ?time$", s) { return .onTime }
        return nil
    }

    // MARK: Times

    static let months: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]

    /// NJT times are Eastern wall-clock strings, either
    /// `03-Aug-2026 09:51:00 AM` or a bare `9:51 AM` (taken as today, or
    /// tomorrow when that would be more than 8 hours in the past).
    public static func rawToDate(_ raw: String, baseNow: Date = Date()) -> Date? {
        let cleaned = clean(raw)
        if let full = RX.match(
            "^(\\d{1,2})-([A-Za-z]{3})-(\\d{4}) (\\d{1,2}):(\\d{2}):(\\d{2}) ([AP]M)$",
            cleaned
        ) {
            guard let month = months[full[2]],
                  let day = Int(full[1]), let year = Int(full[3]),
                  let rawHour = Int(full[4]), let minute = Int(full[5]), let second = Int(full[6]) else {
                return nil
            }
            var hour = rawHour % 12
            if full[7] == "PM" { hour += 12 }
            return Eastern.date(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        }
        guard let timeOnly = RX.match("^(\\d{1,2}):(\\d{2}) ?([AP]M)$", cleaned, ignoreCase: true),
              let rawHour = Int(timeOnly[1]), let minute = Int(timeOnly[2]) else {
            return nil
        }
        var hour = rawHour % 12
        if timeOnly[3].uppercased() == "PM" { hour += 12 }
        let today = Eastern.ymd(of: baseNow)
        guard let candidate = Eastern.date(year: today.year, month: today.month, day: today.day, hour: hour, minute: minute) else {
            return nil
        }
        if candidate < baseNow.addingTimeInterval(-8 * 3600) {
            let tomorrow = Eastern.ymd(of: baseNow.addingTimeInterval(24 * 3600))
            return Eastern.date(year: tomorrow.year, month: tomorrow.month, day: tomorrow.day, hour: hour, minute: minute)
        }
        return candidate
    }

    private static let plannerDate = Eastern.formatter("MM/dd/yyyy")
    private static let plannerTime = Eastern.formatter("h:mm a")
    private static let formatterLock = NSLock()

    /// The trip planner's date ("08/03/2026") and time ("9:51 AM") fields, Eastern.
    public static func plannerMoment(_ now: Date) -> (date: String, time: String) {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return (plannerDate.string(from: now), plannerTime.string(from: now))
    }

    // MARK: Departure boards

    public static func buildBoardIndex(_ items: [JSON]) -> [String: BoardEntry] {
        var map: [String: BoardEntry] = [:]
        for item in items {
            let trainId = clean(item["trainID"])
            if trainId.isEmpty || map[trainId] != nil { continue }
            let noteParts = [clean(item["inlineMessage"]), clean(item["status"])]
                .filter { !$0.isEmpty }
                .filter { $0.lowercased() != "ontime" }
                .filter { !RX.test("^in\\s+\\d+\\s+min$", $0, ignoreCase: true) }
            map[trainId] = BoardEntry(
                track: cleanOrNil(item["track"]),
                // v4 joined these with an em dash; a middle dot keeps the
                // same length (used when ranking duplicates) without one.
                note: noteParts.isEmpty ? nil : noteParts.joined(separator: " · "),
                departureRaw: cleanOrNil(item["departureDate"]),
                status: parseBoardStatus(item["status"].jsString, item["inlineMessage"].jsString)
            )
        }
        return map
    }

    // MARK: Planner itineraries

    /// Human-friendly stop names for transfer notes.
    public static func prettifyStop(_ value: JSON?) -> String {
        let cleaned = RX.replaceAll("\\s+(UPPER|LOWER) LEVEL\\b", in: clean(value), with: "", ignoreCase: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "your connection" }
        if RX.test("WATCHUNG", cleaned, ignoreCase: true) { return "Watchung Ave" }
        if RX.test("SECAUCUS", cleaned, ignoreCase: true) { return "Secaucus" }
        if RX.test("NEWARK BROAD", cleaned, ignoreCase: true) { return "Newark Broad" }
        if RX.test("NEW YORK PENN", cleaned, ignoreCase: true) || RX.test("^PENN STATION NEW YORK$", cleaned, ignoreCase: true) {
            return "Penn Station NY"
        }
        if RX.test("HOBOKEN", cleaned, ignoreCase: true) { return "Hoboken" }
        return titleCase(cleaned.lowercased())
    }

    /// `value.replace(/\b\w/g, c => c.toUpperCase())`
    static func titleCase(_ text: String) -> String {
        let regex = RX.regex("\\b\\w")
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            result.replaceCharacters(in: match.range, with: ns.substring(with: match.range).uppercased())
        }
        return result as String
    }

    /// Rail legs with a train number and both times; walks and buses drop out.
    public static func railLegs(_ legs: [JSON]?) -> [JSON] {
        (legs ?? []).filter { leg in
            clean(leg["routeType"]) == "C"
                && !clean(leg["block"]).isEmpty
                && !clean(leg["onStopTime"]).isEmpty
                && !clean(leg["offStopTime"]).isEmpty
        }
    }

    /// `leg.onStopDescription || previous.offStopDescription`
    static func connectionName(_ leg: JSON, previous: JSON) -> JSON? {
        let on = leg["onStopDescription"]
        return on.truthy ? on : previous["offStopDescription"]
    }

    public static func buildTransferNote(_ legs: [JSON]) -> String? {
        if legs.count < 2 { return nil }
        var parts: [String] = []
        for index in 1..<legs.count {
            let station = prettifyStop(connectionName(legs[index], previous: legs[index - 1]))
            let nextTrain = clean(legs[index]["block"])
            parts.append("Stopover at \(station)" + (nextTrain.isEmpty ? "" : ", continue on Train \(nextTrain)"))
        }
        return parts.joined(separator: ". ") + "."
    }

    public static func transferStops(_ legs: [JSON]) -> [String] {
        guard legs.count > 1 else { return [] }
        return (1..<legs.count)
            .map { prettifyStop(connectionName(legs[$0], previous: legs[$0 - 1])) }
            .filter { !$0.isEmpty }
    }

    /// Turn raw planner itineraries into trips for one direction, one per
    /// train and departure, preferring fewer transfers, then the earlier
    /// arrival, then the shorter note.
    public static func normalizeItineraries(
        _ itineraries: [JSON],
        fromId: String,
        toId: String,
        boardIndex: [String: BoardEntry],
        baseNow: Date = Date()
    ) -> [Trip] {
        var order: [String] = []
        var deduped: [String: Trip] = [:]
        for itinerary in itineraries {
            let legs = railLegs(itinerary["legs"]?.arrayValue)
            guard let first = legs.first, let last = legs.last else { continue }
            let trainId = cleanOrNil(first["block"])
            let board = trainId.flatMap { boardIndex[$0] }
            guard let departureRaw = cleanOrNil(first["onStopTime"]) ?? board?.departureRaw,
                  let departure = rawToDate(departureRaw, baseNow: baseNow) else {
                continue
            }
            let arrival = cleanOrNil(last["offStopTime"]).flatMap { rawToDate($0, baseNow: baseNow) }

            let transferCount = max(0, legs.count - 1)
            var noteParts: [String] = []
            if let transferNote = buildTransferNote(legs) { noteParts.append(transferNote) }
            if let boardNote = board?.note { noteParts.append(boardNote) }

            let trip = Trip(
                fromId: fromId,
                toId: toId,
                trainId: trainId,
                departure: departure,
                arrival: arrival,
                track: board?.track,
                transferCount: transferCount,
                transferAt: transferCount > 0 ? transferStops(legs) : [],
                legTrainIds: legs.map { clean($0["block"]) }.filter { !$0.isEmpty },
                note: noteParts.isEmpty ? nil : noteParts.joined(separator: " "),
                status: board?.status,
                statusNote: board?.note
            )

            let key = "\(fromId)|\(toId)|\(trainId ?? "na")|\(ISOTime.string(from: departure))"
            if let existing = deduped[key] {
                if compareTripPreference(trip, existing) < 0 { deduped[key] = trip }
            } else {
                order.append(key)
                deduped[key] = trip
            }
        }
        return order.compactMap { deduped[$0] }.stableSorted { $0.departure < $1.departure }
    }

    /// Negative when `a` is the better itinerary for the same train and time.
    public static func compareTripPreference(_ a: Trip, _ b: Trip) -> Double {
        if a.transferCount != b.transferCount { return Double(a.transferCount - b.transferCount) }
        let arrivalA = a.arrival?.epochMs ?? Double(Int64.max)
        let arrivalB = b.arrival?.epochMs ?? Double(Int64.max)
        if arrivalA != arrivalB { return arrivalA - arrivalB }
        return Double((a.note?.utf16.count ?? 0) - (b.note?.utf16.count ?? 0))
    }

    // MARK: Stop lists

    /// Valid, de-duplicated train numbers from a comma-separated list, capped
    /// so one refresh can't fan out into dozens of requests.
    public static func parseTrainIds(_ value: String?) -> [String] {
        var seen: [String] = []
        for raw in (value ?? "").split(separator: ",", omittingEmptySubsequences: false) {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !RX.test("^[A-Za-z0-9]{1,6}$", id) { continue }
            if !seen.contains(id) { seen.append(id) }
            if seen.count >= NJTQueries.maxStopListTrains { break }
        }
        return seen
    }

    /// A train's stop list with NJT's real-time departed flags.
    public static func parseStops(_ list: [JSON], baseNow: Date = Date()) -> [TrainStop] {
        list.compactMap { raw in
            let name = clean(raw["name"])
            if name.isEmpty { return nil }
            let timeRaw = raw["time"]
            return TrainStop(
                name: name,
                time: timeRaw.truthy ? rawToDate(clean(timeRaw), baseNow: baseNow) : nil,
                departed: raw["departed"]?.isTrue ?? false,
                status: cleanOrNil(raw["status"]),
                note: cleanOrNil(raw["dropOff"])
            )
        }
    }
}
