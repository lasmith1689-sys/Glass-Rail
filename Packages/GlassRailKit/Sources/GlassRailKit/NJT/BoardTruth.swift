import Foundation

/// NJ Transit's departure boards are its live record of which trains run
/// today and where they go; the trip planner only knows the timetable. When
/// they disagree, the boards win. On Monday 5 October 2026, with New York
/// Penn Station closed to Midtown Direct trains, the planner still routed
/// train 6222 from Watchung Avenue to Penn Station (and to Hoboken by a change
/// at Secaucus), while Watchung Avenue's board, rightly, said "Hoboken"; and
/// it had no idea 6231 now started from Hoboken, which Hoboken's board listed.
public enum BoardTruth {
    /// Trips for one direction, checked against the boards read at `fetchedAt`.
    ///
    /// From home, every train on the home station's board bound for the city
    /// is listed. One that runs to this trip's destination is a direct trip,
    /// whatever the timetable says; one that runs elsewhere keeps only the
    /// connections that still work (see `NJTParse.connectionFits`), or else is
    /// listed as ending where it really ends (`Trip.terminus`).
    ///
    /// Home from the city, a train on both the origin's board and the home
    /// station's (heading out of the city) is a direct trip home.
    ///
    /// Trips on trains the boards don't mention are left as the planner gave
    /// them, and so is every trip when the home station's board didn't load.
    public static func reconcile(
        _ trips: [Trip],
        pair: ODPair,
        boards: [String: [String: BoardEntry]],
        fetchedAt: Date
    ) -> [Trip] {
        let home = UserConfig.homeId
        guard let homeBoard = boards[home], !homeBoard.isEmpty else { return trips }
        if pair.fromId == home {
            return fromHome(trips, pair: pair, homeBoard: homeBoard, fetchedAt: fetchedAt)
        }
        if pair.toId == home, let originBoard = boards[pair.fromId], !originBoard.isEmpty {
            return toHome(trips, pair: pair, homeBoard: homeBoard, originBoard: originBoard, fetchedAt: fetchedAt)
        }
        return trips
    }

    /// True when the home station's board lists a train bound for the city,
    /// which answers "what leaves for the city" even if the planner doesn't.
    public static func homeBoardAnswers(_ homeBoard: [String: BoardEntry]?) -> Bool {
        homeBoard?.values.contains { NJTParse.isTowardCity($0.destination) } ?? false
    }

    static func fromHome(_ trips: [Trip], pair: ODPair, homeBoard: [String: BoardEntry], fetchedAt: Date) -> [Trip] {
        var result = trips
        for (train, entry) in homeBoard where NJTParse.isTowardCity(entry.destination) {
            guard let departure = entry.departureRaw.flatMap({ NJTParse.rawToDate($0, baseNow: fetchedAt) }) else { continue }
            let served = NJTParse.servedTerminal(entry.destination)
            let planned = result.filter { $0.trainId == train }
            var keep: [Trip]
            if served == pair.toId {
                // It runs there: a direct trip, the planner's if it agrees.
                keep = planned.filter { $0.transferCount == 0 && $0.terminus == nil }
                if keep.isEmpty {
                    keep = [boardTrip(train, entry, pair: pair, departure: departure, arrival: nil, fetchedAt: fetchedAt, terminus: nil)]
                }
            } else {
                // It runs elsewhere: only connections that still work.
                keep = planned.filter { NJTParse.connectionFits($0, firstTrainRunsTo: served) }
                if keep.isEmpty {
                    let terminus = served.flatMap { Stations.station($0)?.shortLabel } ?? entry.destination ?? "another station"
                    keep = [boardTrip(train, entry, pair: pair, departure: departure, arrival: nil, fetchedAt: fetchedAt, terminus: terminus)]
                }
            }
            result.removeAll { $0.trainId == train }
            result.append(contentsOf: keep)
        }
        return result.stableSorted { $0.departure < $1.departure }
    }

    static func toHome(
        _ trips: [Trip],
        pair: ODPair,
        homeBoard: [String: BoardEntry],
        originBoard: [String: BoardEntry],
        fetchedAt: Date
    ) -> [Trip] {
        var result = trips
        for (train, atHome) in homeBoard where !NJTParse.isTowardCity(atHome.destination) {
            guard let origin = originBoard[train],
                  let leaves = origin.departureRaw.flatMap({ NJTParse.rawToDate($0, baseNow: fetchedAt) }),
                  let arrives = atHome.departureRaw.flatMap({ NJTParse.rawToDate($0, baseNow: fetchedAt) }),
                  arrives > leaves, arrives.timeIntervalSince(leaves) < 3 * 3600 else { continue }
            if result.contains(where: { $0.trainId == train && $0.transferCount == 0 }) { continue }
            result.append(boardTrip(train, origin, pair: pair, departure: leaves, arrival: arrives, fetchedAt: fetchedAt, terminus: nil))
        }
        return result.stableSorted { $0.departure < $1.departure }
    }

    /// A trip built from a board: one train, its track, status and countdown.
    static func boardTrip(
        _ train: String,
        _ entry: BoardEntry,
        pair: ODPair,
        departure: Date,
        arrival: Date?,
        fetchedAt: Date,
        terminus: String?
    ) -> Trip {
        Trip(
            fromId: pair.fromId,
            toId: pair.toId,
            trainId: train,
            departure: departure,
            arrival: arrival,
            track: entry.track,
            transferCount: 0,
            transferAt: [],
            legTrainIds: [train],
            note: entry.note,
            status: entry.status,
            statusNote: entry.note,
            listedAt: fetchedAt,
            countdownMinutes: entry.countdownMinutes,
            terminus: terminus
        )
    }
}
