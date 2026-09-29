import GlassRailKit
import SwiftUI
import WidgetKit

// Live Activity layouts. Compiled into the widget extension and into the app
// (the widget gallery draws the Lock Screen view for CI screenshots).
//
// Nothing here reads the clock. The system draws a Live Activity only when
// its content changes (or once, at the stale date), and while the app is
// suspended there are no content changes. So every part that depends on the
// time is a view the system keeps current by itself: relative times
// ("in 4 minutes", "3 minutes ago"), timer text, and a timer-driven progress
// bar, all computed from the dates in the content.

/// The Lock Screen presentation. It reads correctly before the pickup, on
/// board and after arrival without a single content update or redraw: the
/// app ends the activity when it goes to the background, and nothing redraws
/// an ended activity until the system dismisses it.
struct RideLockScreenView: View {
    let attributes: RideActivityAttributes
    let state: RideActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tram.fill")
                Text("Train \(attributes.trainId) · \(attributes.fromLabel) → \(attributes.toLabel)")
                    .lineLimit(1)
                Spacer(minLength: 0)
                if state.cancelled {
                    WidgetBadge(text: "Cancelled", tone: .cancel)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))

            HStack(alignment: .top, spacing: 10) {
                RideLeg(label: "Pickup", time: state.departure, late: state.pickupDelayMinutes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let arrival = state.arrival {
                    RideLeg(label: "Drop-off", time: arrival, late: state.dropoffDelayMinutes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Track")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(state.track ?? "--")
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                }
            }

            RideJourneyBar(from: attributes.fromLabel, to: attributes.toLabel, plan: state.plan)

            Text(RideText.footer(state))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(14)
    }
}

/// One end of the ride: its true time, how late it is, and how far away it
/// is ("in 4 minutes", then "now", then "3 minutes ago").
struct RideLeg: View {
    let label: String
    let time: Date
    let late: Int
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 5) {
                Text(label)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.7))
                if late > 0 {
                    Text("\(late)m late")
                        .foregroundStyle(Accent.delay)
                }
            }
            .font(.system(size: 10, weight: .bold))
            Text(Format.time(time))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .minimumScaleFactor(0.8)
            RelativeTime(to: time)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .lineLimit(1)
    }
}

/// "in 4 minutes" / "now" / "3 minutes ago", kept current by the system.
struct RelativeTime: View {
    let to: Date

    var body: some View {
        Text(TimeDataSource<Date>.currentDate, format: .reference(to: to))
    }
}

/// Origin, a timer-driven bar from pickup to drop-off, destination. The
/// system advances the bar, so it follows the ride with the app suspended.
struct RideJourneyBar: View {
    let from: String
    let to: String
    let plan: RidePlan

    var body: some View {
        HStack(spacing: 8) {
            Text(from)
            ProgressView(
                timerInterval: plan.journey,
                countsDown: false,
                label: { EmptyView() },
                currentValueLabel: { EmptyView() }
            )
            .progressViewStyle(.linear)
            .tint(.white)
            Text(to)
        }
        .font(.system(size: 10, weight: .semibold))
        .textCase(.uppercase)
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
    }
}

/// The Dynamic Island's short countdown: to the pickup, then to the drop-off.
/// Only an active (not ended) activity is in the Dynamic Island, and an
/// active one is redrawn at its stale date, which is set to the end of the
/// current phase; `RidePlan.displayed` turns that redraw into the next phase.
struct RideCountdown: View {
    let state: RideActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let phase = RidePlan.displayed(state.phase, isStale: stale)
        if let range = state.plan.countdown(for: phase, updatedAt: state.updatedAt) {
            Text(timerInterval: range, countsDown: true, showsHours: false)
        } else if phase == .arrived {
            Image(systemName: "checkmark.circle.fill")
        } else {
            Image(systemName: "tram.fill")
        }
    }
}

enum RideText {
    /// "Updated 2:31 PM · Past Bay Street · next Glen Ridge": the stop is as
    /// of that time, which the label says rather than implying it is current.
    static func footer(_ state: RideActivityAttributes.ContentState) -> String {
        var text = "Updated \(Format.time(state.updatedAt))"
        if let position = state.position { text += " · \(position)" }
        return text
    }
}
