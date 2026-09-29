import ActivityKit
import Foundation
import GlassRailKit

/// A Live Activity for the ride you pinned: Lock Screen and Dynamic Island
/// show the true pickup and drop-off times, the track, any delay and where
/// the train is, with countdowns that keep running on their own.
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
        /// 0...1 along origin to destination.
        var progress: Double
        var cancelled: Bool
    }

    /// The pin key (`from|to|train`) this activity follows.
    var key: String
    var trainId: String
    var fromLabel: String
    var toLabel: String
}

extension RideActivityAttributes.ContentState {
    /// The activity's content for the featured (pinned) train.
    init(view: TripView, state: BoardState) {
        departure = view.expectedDeparture
        arrival = view.expectedArrival
        pickupDelayMinutes = view.timing?.pickup.delayMinutes ?? view.delayMinutes ?? 0
        dropoffDelayMinutes = view.timing?.dropoff?.delayMinutes ?? 0
        track = view.trip.track
        position = state.heroStops.flatMap { $0.isEmpty ? nil : Format.positionLabel($0) }
        // Two decimals is plenty for the dot and avoids an update every tick.
        progress = (state.progress * 100).rounded() / 100
        cancelled = view.cancelled
    }

    /// Past the pickup time, the ride is underway.
    func riding(at date: Date) -> Bool { date >= departure }
}
