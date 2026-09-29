import ActivityKit
import GlassRailKit
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentation of a pinned ride. The layouts
/// live in Shared/RideActivityViews.swift; none of them reads the clock.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(hex: 0x15203A).opacity(0.72))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "glassrail://board"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RideLeg(label: "Pickup", time: state.departure, late: state.pickupDelayMinutes)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let arrival = state.arrival {
                        RideLeg(label: "Drop-off", time: arrival, late: state.dropoffDelayMinutes, alignment: .trailing)
                            .padding(.trailing, 4)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Track")
                                .font(.system(size: 10, weight: .bold))
                                .textCase(.uppercase)
                                .foregroundStyle(.white.opacity(0.7))
                            Text(state.track ?? "--")
                                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        }
                        .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        RideJourneyBar(from: context.attributes.fromLabel, to: context.attributes.toLabel, plan: state.plan)
                        HStack(spacing: 6) {
                            Text("Train \(context.attributes.trainId) · Track \(state.track ?? "--")")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if state.cancelled {
                                WidgetBadge(text: "Cancelled", tone: .cancel)
                            }
                        }
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
                RideCountdown(state: state, stale: context.isStale)
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
