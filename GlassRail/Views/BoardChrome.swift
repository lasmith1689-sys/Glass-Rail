import GlassRailKit
import SwiftUI

/// "Rail planner / Glass Rail" with the freshness badges.
struct HeaderBar: View {
    let feedMode: FeedMode?
    let generatedAt: Date?
    let now: Date
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rail planner").kicker()
                Text("Glass Rail")
                    .grFont(23.2, .semibold, style: .title2, maxScale: 1.3)
                    .tracking(-0.6)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if let feedMode {
                    FeedBadge(mode: feedMode)
                }
                if let generatedAt {
                    Text(Format.freshness(generatedAt: generatedAt, now: now))
                        .grFont(9.9, .semibold, style: .caption2, maxScale: 1.3, digits: true)
                        .foregroundStyle(theme.ink.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .pillSurface()
                }
                if feedMode == .stale {
                    Text("Data may be outdated.")
                        .grFont(9.9, .semibold, style: .caption2, maxScale: 1.3)
                        .foregroundStyle(theme.ink.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// "Your ride", the AM/PM flip, and the Hoboken / Penn toggle.
struct RouteBar: View {
    let state: BoardState
    let destinationId: String
    let isOverridden: Bool
    let onFlip: () -> Void
    let onSelectDestination: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Your ride").kicker()
                        Text(state.commuteMode == .am ? "AM" : "PM")
                            .grFont(9.5, .heavy, style: .caption2, maxScale: 1.3)
                            .tracking(0.8)
                            .foregroundStyle(theme.ink.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill((state.commuteMode == .am ? Accent.am : Accent.pm).opacity(0.28)))
                            .accessibilityLabel(state.commuteMode == .am ? "Morning direction" : "Evening direction")
                    }
                    HStack(spacing: 0) {
                        Text(state.from.shortLabel)
                        Text(" → ").foregroundStyle(theme.ink.opacity(0.6))
                        Text(state.to.shortLabel)
                    }
                    .grFont(15.7, .semibold, style: .headline, maxScale: 1.4)
                    .tracking(-0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(state.from.shortLabel) to \(state.to.shortLabel)")
                }
                Spacer(minLength: 0)
                GlassIconButton(systemImage: "arrow.left.arrow.right", label: "Flip direction", action: onFlip)
                    .accessibilityHint(isOverridden ? "Switched by hand until the clock next crosses 2 PM or midnight" : "Direction follows the clock: toward the city until 2 PM, home after")
            }
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(UserConfig.destinationIds, id: \.self) { id in
                        if let station = Stations.station(id) {
                            DestinationPill(
                                station: station,
                                selected: destinationId == id,
                                action: { onSelectDestination(id) }
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetPanel(radius: 24)
    }
}

struct DestinationPill: View {
    let station: Station
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let accent = Accent.destination(station.id)
        Button(action: action) {
            Text(station.code ?? station.shortLabel)
                .grFont(11.2, .bold, style: .caption, maxScale: 1.4)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(theme.ink.opacity(selected ? 1 : 0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? Glass.regular.tint(accent.opacity(0.3)).interactive() : Glass.regular.interactive(), in: Capsule())
        .overlay {
            if selected {
                Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 2)
            }
        }
        .accessibilityLabel("Destination \(station.shortLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Later this way": the next departures at a glance; opens the full list.
struct LaterTeaser: View {
    let later: [TripView]
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Later this way").kicker()
                    if later.isEmpty {
                        Text("Nothing later.")
                            .grFont(12.5, style: .footnote)
                            .foregroundStyle(theme.ink.opacity(0.75))
                    } else {
                        HStack(spacing: 0) {
                            Text(later.prefix(3).map { Format.time($0.expectedDeparture) }.joined(separator: " · "))
                                .foregroundStyle(theme.ink.opacity(0.85))
                            if later.count > 3 {
                                Text(" + \(later.count - 3) more")
                                    .fontWeight(.medium)
                                    .foregroundStyle(theme.ink.opacity(0.72))
                            }
                        }
                        .grFont(15, .semibold, style: .headline, maxScale: 1.4, digits: true)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.75))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(later.isEmpty)
        .opacity(later.isEmpty ? 0.5 : 1)
        .insetPanel(radius: 16)
        .accessibilityHint("Shows later trains; tap one to pin it")
    }
}

/// Refresh, freshness and Settings.
struct FooterBar: View {
    let generatedAt: Date?
    let now: Date
    let refreshing: Bool
    let onRefresh: () -> Void
    let onSettings: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onRefresh) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                        .symbolEffect(.rotate, isActive: refreshing)
                    Text("Refresh")
                        .grFont(13.1, .semibold, style: .subheadline, maxScale: 1.3)
                }
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            Spacer(minLength: 0)
            if let generatedAt {
                Text(Format.freshness(generatedAt: generatedAt, now: now))
                    .grFont(10.9, style: .caption, maxScale: 1.3, digits: true)
                    .foregroundStyle(theme.ink.opacity(0.75))
            }
            GlassIconButton(systemImage: "gearshape", label: "Settings", size: 32, action: onSettings)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}
