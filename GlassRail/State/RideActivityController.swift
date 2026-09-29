import ActivityKit
import Foundation
import GlassRailKit

/// Starts, updates and ends the Live Activity for a pinned ride.
///
/// Started when the rider pins a train, kept current while the app runs
/// (true times, track, position), and ended when the pin is released or the
/// ride is over (a few minutes after arrival, the board's own rule). There is
/// no push server, so while the app is suspended the activity keeps its last
/// times and its countdowns run on the device.
@MainActor
final class RideActivityController {
    private var lastContent: RideActivityAttributes.ContentState?
    private var lastKey: String?

    func sync(pin: Pin?, state: BoardState?, now: Date) {
        guard let pin else {
            end(except: nil)
            return
        }
        guard let state, pin.dirKey == state.dirKey else {
            // Looking the other way: leave the ride's activity as it is.
            return
        }
        guard state.isPinned, let hero = state.hero, hero.key == pin.key, let trainId = hero.trip.trainId else {
            // The pinned ride has ended (or its train is unknown).
            end(except: nil)
            return
        }
        let content = RideActivityAttributes.ContentState(view: hero, state: state)
        let existing = Activity<RideActivityAttributes>.activities.first { $0.attributes.key == pin.key }
        end(except: pin.key)
        if let existing {
            guard content != lastContent || lastKey != pin.key else { return }
            lastContent = content
            lastKey = pin.key
            let update = ActivityContent(state: content, staleDate: Self.staleDate(content, now: now))
            Task { await existing.update(update) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = RideActivityAttributes(
            key: pin.key,
            trainId: trainId,
            fromLabel: state.from.shortLabel,
            toLabel: state.to.shortLabel
        )
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: Self.staleDate(content, now: now)),
                pushType: nil
            )
            lastContent = content
            lastKey = pin.key
        } catch {
            // Live Activities turned off, or too many running: the board still works.
        }
    }

    /// End every ride activity except the one for `key`.
    private func end(except key: String?) {
        for activity in Activity<RideActivityAttributes>.activities where activity.attributes.key != key {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        if key == nil {
            lastContent = nil
            lastKey = nil
        }
    }

    /// Shown as stale once the rider should be off the train.
    private static func staleDate(_ content: RideActivityAttributes.ContentState, now: Date) -> Date {
        if let arrival = content.arrival { return arrival.addingTimeInterval(Status.rideArrivalGrace) }
        return max(now, content.departure).addingTimeInterval(Status.rideNoArrivalTTL)
    }
}
