import ActivityKit
import GlassRailKit
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentation of a pinned ride.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color(hex: 0x15203A).opacity(0.72))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "glassrail://board"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.riding(at: Date()) ? "Drop-off" : "Pickup")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(Format.time(state.riding(at: Date()) ? (state.arrival ?? state.departure) : state.departure))
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Track")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(state.track ?? "--")
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RideProgressBar(from: context.attributes.fromLabel, to: context.attributes.toLabel, progress: state.progress)
                    if let position = state.position {
                        Text(position)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Label {
                    Text(context.attributes.trainId).monospacedDigit()
                } icon: {
                    Image(systemName: "tram.fill")
                }
                .font(.system(size: 13, weight: .semibold))
            } compactTrailing: {
                RideCountdown(state: state)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "tram.fill")
            }
            .keylineTint(Accent.hoboken)
            .widgetURL(URL(string: "glassrail://board"))
        }
    }
}

/// Counts down to the pickup, then to the drop-off.
struct RideCountdown: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        let now = Date()
        if !state.riding(at: now) {
            Text(timerInterval: now...state.departure, countsDown: true, showsHours: false)
        } else if let arrival = state.arrival, arrival > now {
            Text(timerInterval: now...arrival, countsDown: true, showsHours: false)
        } else {
            Text("Now")
        }
    }
}

struct RideProgressBar: View {
    let from: String
    let to: String
    let progress: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(from)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                    Capsule()
                        .fill(LinearGradient(colors: [Accent.hoboken, .white, Accent.penn], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, proxy.size.width * progress), height: 3)
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .offset(x: min(max(0, proxy.size.width * progress - 4), max(0, proxy.size.width - 8)))
                }
                .frame(height: proxy.size.height)
            }
            .frame(height: 8)
            Text(to)
        }
        .font(.system(size: 10, weight: .semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct RideLockScreenView: View {
    let attributes: RideActivityAttributes
    let state: RideActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let riding = state.riding(at: Date())
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tram.fill")
                Text("Train \(attributes.trainId) · \(attributes.fromLabel) → \(attributes.toLabel)")
                    .lineLimit(1)
                Spacer(minLength: 0)
                if state.cancelled {
                    WidgetBadge(text: "Cancelled", tone: .cancel)
                } else if state.pickupDelayMinutes > 0 && !riding {
                    WidgetBadge(text: "Delayed \(state.pickupDelayMinutes)m", tone: .delay)
                } else if stale {
                    Text("Not updating")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))

            HStack(alignment: .firstTextBaseline) {
                RideLeg(label: "Pickup", time: state.departure, late: state.pickupDelayMinutes, dimmed: riding)
                Spacer(minLength: 8)
                if let arrival = state.arrival {
                    RideLeg(label: "Drop-off", time: arrival, late: state.dropoffDelayMinutes, dimmed: false)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(riding ? "Arrives in" : "Leaves in")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    RideCountdown(state: state)
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80, alignment: .trailing)
                    Text("Track \(state.track ?? "--")")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            RideProgressBar(from: attributes.fromLabel, to: attributes.toLabel, progress: state.progress)
            if let position = state.position {
                Text(position)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

struct RideLeg: View {
    let label: String
    let time: Date
    let late: Int
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.7))
            Text(Format.time(time))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
            Text(late > 0 ? "\(late)m late" : "On time")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(late > 0 ? Accent.delay : .white.opacity(0.7))
        }
        .opacity(dimmed ? 0.6 : 1)
    }
}
