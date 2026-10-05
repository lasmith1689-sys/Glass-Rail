import Foundation

/// Port of lib/format.ts, plus the small label helpers that lived in board.tsx.
public enum Format {
    private static let timeFormatter = Eastern.formatter("h:mm a")
    private static let lock = NSLock()

    /// "5:08 PM", always in Eastern time.
    public static func time(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return timeFormatter.string(from: date)
    }

    /// "Now", "in 12m", "in 1h 5m", "in 2h".
    public static func countdown(to date: Date, now: Date) -> String {
        let minutes = jsRound((date.epochMs - now.epochMs) / 60_000)
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder != 0 ? "in \(hours)h \(remainder)m" : "in \(hours)h"
    }

    /// "Fresh 12s ago", "Updated 4m ago", "Updated 2h ago".
    public static func freshness(generatedAt: Date, now: Date) -> String {
        let ageMs = max(0, now.epochMs - generatedAt.epochMs)
        let ageS = jsRound(ageMs / 1000)
        if ageS < 45 { return "Fresh \(ageS)s ago" }
        let ageM = jsRound(ageMs / 60_000)
        if ageM < 60 { return "Updated \(ageM)m ago" }
        let ageH = jsRound(ageMs / 3_600_000)
        return "Updated \(ageH)h ago"
    }

    public static func transferLabel(_ count: Int) -> String {
        if count == 0 { return "Direct" }
        return count == 1 ? "1 transfer" : "\(count) transfers"
    }

    /// "Direct", "1 transfer", or "Ends at Hoboken" for a train that doesn't
    /// run to the destination today (see `Trip.terminus`).
    public static func tripType(_ trip: Trip) -> String {
        if let terminus = trip.terminus { return "Ends at \(terminus)" }
        return transferLabel(trip.transferCount)
    }

    public static func trackLabel(_ track: String?) -> String {
        if let track, !track.isEmpty { return "Track \(track)" }
        return "Track pending"
    }

    /// "Past Bay Street · next Glen Ridge" for the hero's train-position row.
    public static func positionLabel(_ stops: [TrainStop]) -> String {
        let recent = Journey.mostRecentDeparted(stops)
        let upcoming = Journey.nextStop(stops)
        guard let recent else {
            guard let first = stops.first else { return "Stops" }
            if let time = first.time {
                return "Starts at \(first.name) · \(Format.time(time))"
            }
            return "Starts at \(first.name)"
        }
        guard let upcoming else { return "Arrived at \(stops[stops.count - 1].name)" }
        return "Past \(recent.name) · next \(upcoming.name)"
    }

    /// "Arrives in 27m" / "Arriving now" / "En route" while riding a pinned train.
    public static func arrivalCountdown(_ arrival: Date?, now: Date) -> String {
        guard let arrival else { return "En route" }
        let text = countdown(to: arrival, now: now)
        return text == "Now" ? "Arriving now" : "Arrives \(text)"
    }
}
