import Foundation

/// Port of lib/fixture.ts: bundled sample data, shown (always labeled SAMPLE)
/// when NJ Transit can't be reached and there is no live data to fall back on.
public enum SampleFixture {
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
        var trip = Trip(
            fromId: fromId,
            toId: toId,
            trainId: trainId,
            departure: dep,
            arrival: dep.adding(minutes: durationMins)
        )
        configure(&trip)
        return trip
    }

    public static let detail = "Bundled sample data. Live NJ Transit feed unavailable."

    /// Shaped on Watchung Avenue's trains, but from whichever station is home,
    /// so another home's board never reads as "No more trains this way".
    public static func payload(now: Date = Date(), detail: String = SampleFixture.detail) -> Payload {
        let home = UserConfig.homeId
        let trips: [Trip] = [
            // Home -> Hoboken (direct)
            trip(home, "hoboken", -8, 35, "1063", now: now) { $0.track = "2"; $0.status = .onTime },
            trip(home, "hoboken", 22, 35, "1067", now: now) { $0.track = "2"; $0.status = .onTime },
            trip(home, "hoboken", 52, 35, "1071", now: now),
            trip(home, "hoboken", 82, 35, "1075", now: now),
            trip(home, "hoboken", 112, 35, "1079", now: now),

            // Home -> Penn Station NY (mostly transfers at Secaucus)
            trip(home, "penn", 14, 52, "6216", now: now) {
                $0.track = "2"
                $0.transferCount = 1
                $0.transferAt = ["Secaucus"]
                $0.note = "Stopover at Secaucus, continue on Train 3852."
                $0.status = .delayed
                $0.statusNote = "Delayed 10 min"
            },
            trip(home, "penn", 44, 50, "6220", now: now) {
                $0.transferCount = 1
                $0.transferAt = ["Secaucus"]
                $0.note = "Stopover at Secaucus, continue on Train 3856."
            },
            trip(home, "penn", 104, 50, "6228", now: now) {
                $0.transferCount = 1
                $0.transferAt = ["Secaucus"]
                $0.note = "Stopover at Secaucus, continue on Train 3864."
            },

            // Hoboken -> home (return)
            trip("hoboken", home, 6, 35, "1078", now: now) { $0.track = "5" },
            trip("hoboken", home, 36, 35, "1082", now: now),
            trip("hoboken", home, 66, 35, "1086", now: now),
            trip("hoboken", home, 96, 35, "1090", now: now),

            // Penn Station NY -> home (return, via Secaucus)
            trip("penn", home, 11, 55, "3855", now: now) {
                $0.track = "7"
                $0.transferCount = 1
                $0.transferAt = ["Secaucus"]
                $0.note = "Stopover at Secaucus, continue on Train 6219."
                $0.status = .onTime
            },
            trip("penn", home, 41, 55, "3859", now: now) {
                $0.transferCount = 1
                $0.transferAt = ["Secaucus"]
                $0.note = "Stopover at Secaucus, continue on Train 6223."
            },
            trip("penn", home, 71, 55, "3863", now: now) {
                $0.transferCount = 1
                $0.transferAt = ["Secaucus"]
                $0.note = "Stopover at Secaucus, continue on Train 6227."
            },
        ]
        return Payload(generatedAt: now, source: PayloadSource(kind: .sample, detail: detail), trips: trips)
    }
}
