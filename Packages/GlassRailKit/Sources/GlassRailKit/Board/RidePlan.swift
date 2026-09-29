import Foundation

/// Where a pinned ride stands, as its Live Activity shows it.
public enum RidePhase: String, Codable, Sendable, Hashable {
    /// Waiting for the train: count down to the pickup.
    case pickup
    /// On board: count down to the drop-off.
    case riding
    /// Off the train; the activity is about to go away.
    case arrived
}

/// How a Live Activity should leave the screen when the app can no longer
/// look after it.
public enum RideDismissal: Equatable, Sendable {
    case immediate
    case after(Date)
}

/// The timing rules for a pinned ride's Live Activity, kept out of the views
/// so they can be tested. There is no push server, so everything here has to
/// work from the ride's own dates: the app writes them into the activity, and
/// the system renders countdowns and relative times from them on its own.
public struct RidePlan: Equatable, Sendable {
    /// True pickup time.
    public var departure: Date
    /// True drop-off time, when known.
    public var arrival: Date?

    public init(departure: Date, arrival: Date?) {
        self.departure = departure
        self.arrival = arrival
    }

    /// When the ride is over: a few minutes after arrival, the same rule the
    /// board uses to stop featuring a pinned ride (`Status.rideView`). Without
    /// an arrival time, a bounded while after departure.
    public var endsAt: Date {
        if let arrival = validArrival { return arrival.addingTimeInterval(Status.rideArrivalGrace) }
        return departure.addingTimeInterval(Status.rideNoArrivalTTL)
    }

    /// An arrival before the departure is bad data; treat it as unknown.
    var validArrival: Date? {
        guard let arrival, arrival >= departure else { return nil }
        return arrival
    }

    public func phase(at now: Date) -> RidePhase {
        if now < departure { return .pickup }
        if let arrival = validArrival {
            return now < arrival ? .riding : .arrived
        }
        return now < endsAt ? .riding : .arrived
    }

    /// When the phase at `now` stops being right. Used as the content's
    /// stale date, so the system re-renders the activity at that moment even
    /// when the app is not running.
    public func phaseEnds(at now: Date) -> Date {
        switch phase(at: now) {
        case .pickup: return departure
        case .riding: return validArrival ?? endsAt
        case .arrived: return endsAt
        }
    }

    public func isOver(at now: Date) -> Bool {
        now >= endsAt
    }

    /// The phase to draw for content made in `phase`. Its stale date is the
    /// end of that phase, so once the system marks it stale the ride has
    /// moved on by one step.
    public static func displayed(_ phase: RidePhase, isStale: Bool) -> RidePhase {
        guard isStale else { return phase }
        switch phase {
        case .pickup: return .riding
        case .riding, .arrived: return .arrived
        }
    }

    /// What to do with the activity when the app goes to the background: it
    /// must leave the Lock Screen when the ride is over, with or without the
    /// app, so it is ended with a dismissal date the system enforces.
    public func dismissal(now: Date) -> RideDismissal {
        isOver(at: now) ? .immediate : .after(endsAt)
    }

    /// The span of a countdown for `phase`: to the pickup, then to the
    /// drop-off. Nil when there is nothing to count down to.
    /// `updatedAt` is when the content was made (always in the past), so a
    /// pickup countdown drawn from it runs from now to the pickup.
    public func countdown(for phase: RidePhase, updatedAt: Date) -> ClosedRange<Date>? {
        switch phase {
        case .pickup:
            return Self.range(min(updatedAt, departure), departure)
        case .riding:
            guard let arrival = validArrival else { return nil }
            return Self.range(departure, arrival)
        case .arrived:
            return nil
        }
    }

    /// The journey bar's span, pickup to drop-off (to the end of the ride
    /// when there is no arrival time). Never empty.
    public var journey: ClosedRange<Date> {
        let end = validArrival ?? endsAt
        return Self.range(departure, max(end, departure.addingTimeInterval(60)))
    }

    /// A closed range that never traps, whatever order the dates come in.
    public static func range(_ a: Date, _ b: Date) -> ClosedRange<Date> {
        a <= b ? a...b : b...a
    }
}

/// Which Live Activities the app keeps.
public enum RideActivityRules {
    /// An activity survives only while it follows the current pin and its
    /// ride is not over. This does not depend on which direction the board
    /// is showing, so a ride that crosses 2 PM or midnight still ends on time.
    public static func shouldKeep(activityKey: String, pinKey: String?, plan: RidePlan, now: Date) -> Bool {
        guard let pinKey, activityKey == pinKey else { return false }
        return !plan.isOver(at: now)
    }
}
