// Why a train on the home station's board has no way home in one direction
// (step 3b in main.swift), told stage by stage as `NJTClient.fetchLivePayload`
// builds a direction's trips:
//
//   1. the direction's planner window failed (Payload.unanswered/carriedOver);
//   2. no per-train lookup was made for the train (NJTClient.plannerSeeds:
//      soonest first, at most NJTQueries.seedsForShownDirection);
//   3. no planner itinerary, clock or per-train, rides the train at all
//      (the per-train lookup's own answer is listed, or its failure);
//   4. every itinerary on it also rides PATH, the subway or a bus
//      (NJTParse.usesOtherTransit), or none ends on it (NJTParse.railLegs);
//   5. normalizeItineraries keeps one trip per first train and departure,
//      and another itinerary from the same first train won (fewer
//      transfers, then the earlier arrival: compareTripPreference). That is
//      the app working as built, so it is marked as an expected exemption.
//
// BoardTruth.reconcile never removes a trip on the way home (it only adds
// direct board trips and marks some cancelled), so it is not a stage here.
//
// The window is asked again to see this: the per-train and pinned clock
// lookups come from the client's cache, as the refresh left them; only the
// first clock lookup (from now) is asked afresh, so a train that only it
// would have dropped shows as "not reproduced". Informational only: nothing
// here changes what the probe or the app passes or fails.
import Foundation
import GlassRailKit

/// The last rail train of an itinerary: the one that reaches home.
private func lastRailTrain(_ itinerary: JSON) -> String? {
    NJTParse.railLegs(itinerary["legs"]?.arrayValue).last.map { NJTParse.clean($0["block"]) }
}

private func rides(_ itinerary: JSON, train: String) -> Bool {
    (itinerary["legs"]?.arrayValue ?? []).contains { NJTParse.clean($0["block"]) == train }
}

private func clockTime(_ value: JSON?, baseNow: Date) -> String {
    let raw = NJTParse.clean(value)
    return NJTParse.rawToDate(raw, baseNow: baseNow).map(Format.time) ?? (raw.isEmpty ? "?" : raw)
}

/// "6253 dep 5:10 PM > 6255 arr 6:02 PM, 1 change": first and last rail train.
private func shortItinerary(_ itinerary: JSON, baseNow: Date) -> String {
    let legs = NJTParse.railLegs(itinerary["legs"]?.arrayValue)
    guard let first = legs.first, let last = legs.last else { return "no rail legs" }
    let changes = legs.count - 1
    let head = "\(NJTParse.clean(first["block"])) dep \(clockTime(first["onStopTime"], baseNow: baseNow))"
    let tail = "\(NJTParse.clean(last["block"])) arr \(clockTime(last["offStopTime"], baseNow: baseNow))"
    let other = NJTParse.usesOtherTransit(itinerary["legs"]?.arrayValue) ? ", other transit" : ""
    return changes == 0 ? "\(head) direct, arr \(clockTime(last["offStopTime"], baseNow: baseNow))\(other)"
        : "\(head) > \(tail), \(changes) change\(changes == 1 ? "" : "s")\(other)"
}

/// Each summary once, in first-seen order (lookups repeat itineraries).
private func distinct(_ items: [String]) -> [String] {
    var seen = Set<String>()
    return items.filter { seen.insert($0).inserted }
}

private func tripSummary(_ trip: Trip) -> String {
    let legs = trip.legTrainIds ?? [trip.trainId].compactMap { $0 }
    let arrival = trip.arrival.map(Format.time) ?? "?"
    return "\(legs.joined(separator: ">")) dep \(Format.time(trip.departure)) arr \(arrival), \(trip.transferCount) change\(trip.transferCount == 1 ? "" : "s")"
}

/// One reason per train in `missing` (home board trains with no trip in
/// `pair`, a direction home from the city), and whether it is an expected
/// exemption (stage 5).
func explainMissingTrainsHome(
    _ missing: [String],
    pair: ODPair,
    homeIndex: [String: BoardEntry],
    payload: Payload,
    client: NJTClient,
    now: Date
) async -> [(train: String, reason: String, expected: Bool)] {
    guard !missing.isEmpty else { return [] }
    if payload.unanswered?.contains(pair.key) == true || payload.carriedOver?[pair.key] != nil {
        return missing.map { ($0, "stage 1: the \(pair.key) planner window failed this refresh, so the direction has no trips of its own", false) }
    }
    guard let from = Stations.station(pair.fromId), let to = Stations.station(pair.toId) else {
        return missing.map { ($0, "unknown station in \(pair.key)", false) }
    }

    // The same seeds the refresh asked for (required: nil, so every
    // direction gets the shown direction's limit), and the same horizon.
    let limit = NJTQueries.seedsForShownDirection
    let horizon = TimeInterval(max(NJTQueries.seedHorizonMinutes, NJTQueries.plannerOffsetsMinutes.max() ?? 0, 60) * 60)
    let seeds = NJTClient.plannerSeeds(for: pair, homeBoard: homeIndex, now: now, horizon: horizon, limit: limit)
    let window = await client.plannerWindow(origin: from.plannerName, destination: to.plannerName, seeds: seeds)
    let originIndex = NJTParse.buildBoardIndex((try? await client.fetchDepartureBoard(from.name)) ?? [])
    let kept = NJTParse.normalizeItineraries(window.itineraries, fromId: pair.fromId, toId: pair.toId, boardIndex: originIndex, baseNow: now)

    var out: [(train: String, reason: String, expected: Bool)] = []
    for train in missing {
        let atHome = homeIndex[train]?.departureRaw.flatMap { NJTParse.rawToDate($0, baseNow: now) }
        let atHomeText = atHome.map(Format.time) ?? "?"
        let onOriginBoard = originIndex[train] == nil
            ? "not on \(from.shortLabel)'s board"
            : "on \(from.shortLabel)'s board leaving \(originIndex[train]?.departureRaw.flatMap { NJTParse.rawToDate($0, baseNow: now) }.map(Format.time) ?? "?")"
        let context = "reaches \(to.shortLabel) \(atHomeText), \(onOriginBoard)"

        // Stage 2: a per-train lookup for this train's time at home.
        guard let atHome, let seed = seeds.first(where: { $0.at == atHome }) else {
            let why = seeds.count >= limit
                ? "the \(limit) per-train lookups (soonest first) ran out before it"
                : "it was not among the per-train lookups' times"
            out.append((train, "stage 2: no per-train lookup, \(why); \(context)", false))
            continue
        }

        // Stage 3: does any itinerary ride it?
        let onTrain = window.itineraries.filter { rides($0, train: train) }
        if onTrain.isEmpty {
            let single = await client.plannerWindow(origin: from.plannerName, destination: to.plannerName, offsets: [], seeds: [seed])
            let answer: String
            if single.failedSeeds > 0 {
                answer = "its arrive-by \(Format.time(seed.at)) lookup failed"
            } else if single.itineraries.isEmpty {
                answer = "its arrive-by \(Format.time(seed.at)) lookup answered no trips"
            } else {
                answer = "its arrive-by \(Format.time(seed.at)) lookup offered "
                    + distinct(single.itineraries.map { shortItinerary($0, baseNow: now) }).joined(separator: "; ")
            }
            out.append((train, "stage 3: no planner itinerary from \(from.shortLabel) rides it in any of \(window.lookups) clock and \(window.seedLookups) per-train lookups; \(answer); \(context)", false))
            continue
        }

        // Stage 4: itineraries the parser can use, ending on this train.
        let usable = onTrain.filter { !NJTParse.usesOtherTransit($0["legs"]?.arrayValue) && lastRailTrain($0) == train }
        if usable.isEmpty {
            let allOther = onTrain.allSatisfy { NJTParse.usesOtherTransit($0["legs"]?.arrayValue) }
            let why = allOther
                ? "every itinerary on it also rides PATH, the subway or a bus (usesOtherTransit drops them)"
                : "no usable itinerary ends on it (it is not the last rail leg with times)"
            // Every leg (route type, train, stops, times), each distinct itinerary once.
            let shown = distinct(onTrain.map { allOther ? legsSummary($0) : shortItinerary($0, baseNow: now) })
            out.append((train, "stage 4: \(why): " + shown.joined(separator: "; ") + "; \(context)", false))
            continue
        }
        let own = NJTParse.normalizeItineraries(usable, fromId: pair.fromId, toId: pair.toId, boardIndex: originIndex, baseNow: now)
        if own.isEmpty {
            out.append((train, "stage 4: its itineraries have no departure time the parser can read: " + usable.map { shortItinerary($0, baseNow: now) }.joined(separator: "; ") + "; \(context)", false))
            continue
        }

        // Stage 5: one trip per first train and departure.
        if kept.contains(where: { ($0.legTrainIds ?? []).last == train }) {
            out.append((train, "not reproduced: asked again, the planner stages keep a trip ending on it (the refresh's first clock lookup may have answered differently); \(context)", false))
            continue
        }
        let beaten = own.compactMap { mine -> String? in
            guard let winner = kept.first(where: { $0.trainId == mine.trainId && $0.departure == mine.departure }) else { return nil }
            let why = winner.transferCount != mine.transferCount
                ? "fewer changes (\(winner.transferCount) vs \(mine.transferCount))"
                : "earlier arrival (\(winner.arrival.map(Format.time) ?? "?") vs \(mine.arrival.map(Format.time) ?? "?"))"
            return "[\(tripSummary(mine))] lost to [\(tripSummary(winner))], same first train and departure, kept for \(why)"
        }
        if beaten.isEmpty {
            out.append((train, "unexplained: its itineraries parse but no trip ending on it or on its first train survived: " + own.map(tripSummary).joined(separator: "; ") + "; \(context)", false))
        } else {
            out.append((train, "stage 5: dominated, expected exemption: " + beaten.joined(separator: "; ") + "; \(context)", true))
        }
    }
    return out
}
