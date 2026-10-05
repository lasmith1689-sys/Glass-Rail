import ActivityKit
import Foundation
import GlassRailKit

/// A Live Activity for the ride you pinned: Lock Screen and Dynamic Island
/// show the true pickup and drop-off times, the track and any delay. Every
/// time-dependent part (relative times, countdowns, the journey bar) is drawn
/// by the system from the dates in the content, so it stays right while the
/// app is suspended.
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// True pickup time at the origin.
        var departure: Date
        /// True drop-off time at the destination, when known.
        var arrival: Date?
        var pickupDelayMinutes: Int
        var dropoffDelayMinutes: Int
        var track: String?
        /// "Past Bay Street · next Glen Ridge", when the stop list is loaded.
        var position: String?
        var cancelled: Bool
        /// When the board's data was fetched ("Updated 2:31 PM").
        var updatedAt: Date
        /// The phase when this content was made. Its stale date is the end of
        /// that phase, so the system's stale re-render moves it on by one.
        var phase: RidePhase

        var plan: RidePlan { RidePlan(departure: departure, arrival: arrival) }

        init(
            departure: Date,
            arrival: Date?,
            pickupDelayMinutes: Int,
            dropoffDelayMinutes: Int,
            track: String?,
            position: String?,
            cancelled: Bool,
            updatedAt: Date,
            phase: RidePhase
        ) {
            self.departure = departure
            self.arrival = arrival
            self.pickupDelayMinutes = pickupDelayMinutes
            self.dropoffDelayMinutes = dropoffDelayMinutes
            self.track = track
            self.position = position
            self.cancelled = cancelled
            self.updatedAt = updatedAt
            self.phase = phase
        }

        enum CodingKeys: String, CodingKey {
            case departure, arrival, pickupDelayMinutes, dropoffDelayMinutes, track, position, cancelled, updatedAt, phase
        }

        /// Lenient, so an activity started by an earlier build (which had no
        /// `updatedAt` or `phase`) still decodes after an update.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            departure = try container.decode(Date.self, forKey: .departure)
            arrival = try container.decodeIfPresent(Date.self, forKey: .arrival)
            pickupDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .pickupDelayMinutes) ?? 0
            dropoffDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .dropoffDelayMinutes) ?? 0
            track = try container.decodeIfPresent(String.self, forKey: .track)
            position = try container.decodeIfPresent(String.self, forKey: .position)
            cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? departure.addingTimeInterval(-3600)
            phase = try container.decodeIfPresent(RidePhase.self, forKey: .phase) ?? .pickup
        }
    }

    /// The pin key (`from|to|train`) this activity follows.
    var key: String
    var trainId: String
    var fromLabel: String
    var toLabel: String
}

extension RideActivityAttributes.ContentState {
    /// The activity's content for the featured (pinned) train.
    init(view: TripView, state: BoardState, updatedAt: Date, now: Date) {
        let plan = RidePlan(departure: view.expectedDeparture, arrival: view.expectedArrival)
        self.init(
            departure: view.expectedDeparture,
            arrival: view.expectedArrival,
            pickupDelayMinutes: view.timing?.pickup.delayMinutes ?? view.delayMinutes ?? 0,
            dropoffDelayMinutes: view.timing?.dropoff?.delayMinutes ?? 0,
            track: view.trip.track,
            position: state.heroStops.flatMap { $0.isEmpty ? nil : Format.positionLabel($0) },
            cancelled: view.cancelled,
            updatedAt: min(updatedAt, now),
            phase: plan.phase(at: now)
        )
    }
}

extension RideActivityAttributes {
    /// A believable ride for the in-app gallery (and CI screenshots): the
    /// board's featured train, or the pinned ride.
    static func preview(state: BoardState, updatedAt: Date, now: Date) -> (RideActivityAttributes, ContentState)? {
        guard let hero = state.hero, let key = hero.key, let trainId = hero.trip.trainId else { return nil }
        let attributes = RideActivityAttributes(
            key: key,
            trainId: trainId,
            fromLabel: state.from.shortLabel,
            toLabel: hero.trip.terminus ?? state.to.shortLabel
        )
        return (attributes, ContentState(view: hero, state: state, updatedAt: updatedAt, now: now))
    }
}
