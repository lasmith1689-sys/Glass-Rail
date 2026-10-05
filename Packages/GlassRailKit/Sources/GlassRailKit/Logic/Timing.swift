import Foundation

/// Port of lib/timing.ts: true pickup and drop-off times from NJT's live stop list.
public struct LegTiming: Equatable, Hashable, Sendable {
    /// Timetable time from the trip planner.
    public var scheduled: Date
    /// Best available estimate: the live stop time when we have one.
    public var expected: Date
    /// Whole minutes behind schedule; never negative.
    public var delayMinutes: Int
    /// True when `expected` came from NJT's live stop list rather than a guess.
    public var live: Bool

    public init(scheduled: Date, expected: Date, delayMinutes: Int, live: Bool) {
        self.scheduled = scheduled
        self.expected = expected
        self.delayMinutes = delayMinutes
        self.live = live
    }
}

public struct TripTiming: Equatable, Hashable, Sendable {
    /// When the rider is picked up at their origin.
    public var pickup: LegTiming
    /// When they are dropped off; nil when the trip has no scheduled arrival.
    public var dropoff: LegTiming?
    public var worstDelayMinutes: Int
    public var late: Bool

    public init(pickup: LegTiming, dropoff: LegTiming?, worstDelayMinutes: Int, late: Bool) {
        self.pickup = pickup
        self.dropoff = dropoff
        self.worstDelayMinutes = worstDelayMinutes
        self.late = late
    }
}

public enum Timing {
    /// A stop time this far from the scheduled time means the list belongs to
    /// a different run (wrong day, recycled train number): ignore it rather
    /// than report a wild delay.
    public static let sanityWindow: TimeInterval = 90 * 60

    static func lateMinutes(scheduled: Date, expected: Date) -> Int {
        let minutes = jsRound((expected.epochMs - scheduled.epochMs) / 60_000)
        return minutes > 0 ? minutes : 0
    }

    static func leg(_ scheduled: Date, _ expected: Date, live: Bool) -> LegTiming {
        LegTiming(
            scheduled: scheduled,
            expected: expected,
            delayMinutes: lateMinutes(scheduled: scheduled, expected: expected),
            live: live
        )
    }

    /// Resolve the two times the rider actually cares about, pickup at their
    /// origin and drop-off at their destination, from NJT's live stop list.
    ///
    /// The legs resolve independently: a train can leave six minutes late and
    /// recover most of it by the destination. Falls back to the delay minutes
    /// parsed from NJT's status text, and finally to the timetable, whenever
    /// live stop times are missing or don't belong to this journey.
    public static func resolveTripTiming(
        stops: [TrainStop]?,
        origin: StationRef,
        dest: StationRef,
        scheduledDeparture: Date,
        scheduledArrival: Date?,
        textDelayMinutes: Int? = nil
    ) -> TripTiming {
        let list = stops ?? []
        let originIdx = list.firstIndex { Journey.stopMatchesStation($0.name, origin) }
        // Boarding at a run's final stop is impossible: a stop list that ends
        // at the rider's origin belongs to some other journey.
        let boardable: Bool
        if let originIdx { boardable = originIdx < list.count - 1 } else { boardable = false }

        var pickup: LegTiming?
        if boardable, let originIdx, let stopTime = list[originIdx].time,
           abs(stopTime.timeIntervalSince(scheduledDeparture)) <= sanityWindow {
            pickup = leg(scheduledDeparture, stopTime, live: true)
        }
        let resolvedPickup: LegTiming
        if let pickup {
            resolvedPickup = pickup
        } else {
            let textDelay = textDelayMinutes ?? 0
            resolvedPickup = leg(
                scheduledDeparture,
                textDelay != 0 ? scheduledDeparture.adding(minutes: textDelay) : scheduledDeparture,
                live: false
            )
        }

        var dropoff: LegTiming?
        if scheduledArrival == nil, pickup != nil, let originIdx {
            // No timetable arrival (a trip read off a departure board): the
            // live run says when it gets there, once its origin time checks out.
            let rest = list[(originIdx + 1)...]
            if let destStop = rest.first(where: { Journey.stopMatchesStation($0.name, dest) }), let stopTime = destStop.time {
                dropoff = leg(stopTime, stopTime, live: true)
            }
        }
        if let scheduledArrival {
            if boardable, let originIdx {
                let rest = list[(originIdx + 1)...]
                if let destStop = rest.first(where: { Journey.stopMatchesStation($0.name, dest) }),
                   let stopTime = destStop.time,
                   abs(stopTime.timeIntervalSince(scheduledArrival)) <= sanityWindow {
                    dropoff = leg(scheduledArrival, stopTime, live: true)
                }
            }
            if dropoff == nil {
                // Destination not on this run (transfer trips) or no usable
                // time: carry the pickup delay forward, but don't present it as live.
                var carried = resolvedPickup.delayMinutes
                if carried == 0 { carried = textDelayMinutes ?? 0 }
                dropoff = leg(
                    scheduledArrival,
                    carried != 0 ? scheduledArrival.adding(minutes: carried) : scheduledArrival,
                    live: false
                )
            }
        }

        let worst = max(resolvedPickup.delayMinutes, dropoff?.delayMinutes ?? 0)
        return TripTiming(pickup: resolvedPickup, dropoff: dropoff, worstDelayMinutes: worst, late: worst > 0)
    }

    /// Fold resolved timing into a trip view so the rest of the UI (hero time,
    /// countdowns, ordering) uses the true times. A live pickup is
    /// authoritative: it can clear a "delayed" flag that came from stale status
    /// text, but it never touches cancellations. Without one, the later of the
    /// two estimates stands, so a departure board saying the train is late
    /// (see `Status.deriveTripView`) isn't undone by the timetable.
    public static func withTiming(_ view: TripView, _ timing: TripTiming) -> TripView {
        let delayed = timing.pickup.live ? timing.late : (view.delayed || timing.late)
        let delayMinutes: Int?
        if timing.pickup.delayMinutes > 0 {
            delayMinutes = timing.pickup.delayMinutes
        } else if timing.pickup.live {
            delayMinutes = nil
        } else {
            delayMinutes = view.delayMinutes
        }
        var next = view
        next.expectedDeparture = timing.pickup.live ? timing.pickup.expected : max(timing.pickup.expected, view.expectedDeparture)
        if let dropoff = timing.dropoff {
            next.expectedArrival = dropoff.live ? dropoff.expected : max(dropoff.expected, view.expectedArrival ?? dropoff.expected)
        }
        next.delayed = delayed
        next.delayMinutes = delayMinutes
        next.timing = timing
        return next
    }
}
