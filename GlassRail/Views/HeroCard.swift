import GlassRailKit
import SwiftUI

/// The featured train (port of v4's Hero): route line with the journey dot,
/// status badges, the true pickup time, the pickup / drop-off pair, transfers,
/// the train's position, and the Service / Type / Track chips.
struct HeroCard: View {
    let state: BoardState
    let now: Date
    let departedLabel: String?
    let departedFading: Bool
    let onShowNext: () -> Void
    let onOpenStops: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RouteLineRow(
                from: state.from.shortLabel,
                to: state.to.shortLabel,
                progress: state.progress,
                showsDot: state.hero != nil
            )
            if let departedLabel {
                DepartedNote(label: departedLabel, fading: departedFading)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
            if let hero = state.hero {
                HeroDetails(
                    view: hero,
                    state: state,
                    now: now,
                    onShowNext: onShowNext,
                    onOpenStops: onOpenStops
                )
            } else {
                NoServiceView(state: state, now: now)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .insetPanel(radius: 24)
        .animation(.snappy, value: departedLabel)
    }
}

private struct HeroDetails: View {
    let view: TripView
    let state: BoardState
    let now: Date
    let onShowNext: () -> Void
    let onOpenStops: () -> Void
    @Environment(\.theme) private var theme

    private var trip: Trip { view.trip }
    private var showsOriginal: Bool { view.delayed && view.delayMinutes != nil }
    private var showsRawNote: Bool {
        guard let note = trip.statusNote, !note.isEmpty else { return false }
        return view.cancelled || (view.delayed && view.delayMinutes == nil)
    }
    /// Live data only (see `BoardState.showsOnTime`).
    private var showsOnTime: Bool { state.showsOnTime(view) }
    private var showsBadgeRow: Bool {
        view.delayed || view.cancelled || view.trackChange != nil || state.isPinned || showsOnTime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBadgeRow {
                badgeRow.padding(.top, 8)
            }
            if showsRawNote, let note = trip.statusNote {
                Text(note)
                    .grFont(11.8, .semibold, style: .footnote)
                    .foregroundStyle(theme.ink.opacity(0.85))
                    .padding(.top, 6)
            }
            timeBlock.padding(.top, 8)
            trainLine.padding(.top, 4)
            if let timing = view.timing {
                HStack(alignment: .top, spacing: 6) {
                    LegCell(label: "Pickup", station: state.from.shortLabel, leg: timing.pickup)
                    if let dropoff = timing.dropoff {
                        LegCell(label: "Drop-off", station: state.to.shortLabel, leg: dropoff)
                    }
                }
                .padding(.top, 10)
            }
            if trip.transferCount > 0 {
                Text(Format.transferLabel(trip.transferCount) + (trip.transferAt.isEmpty ? "" : " at \(trip.transferAt.listed)"))
                    .grFont(12.5, style: .footnote)
                    .foregroundStyle(theme.ink.opacity(0.85))
                    .padding(.top, 4)
            }
            if !state.heroConnections.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(state.heroConnections.enumerated()), id: \.offset) { _, connection in
                        ConnectionRow(connection: connection)
                    }
                }
                .padding(.top, 8)
            }
            if let stops = state.heroStops, !stops.isEmpty {
                PositionButton(trainId: trip.trainId, label: Format.positionLabel(stops), action: onOpenStops)
                    .padding(.top, 10)
            }
            HStack(spacing: 8) {
                MetaChip(label: "Service", value: trip.trainId.map { "#\($0)" } ?? "--")
                MetaChip(label: "Type", value: Format.transferLabel(trip.transferCount))
                MetaChip(label: "Track", value: trip.track.map { "Tk \($0)" } ?? "Pending", highlight: view.trackChange != nil)
            }
            .padding(.top, 10)
        }
    }

    private var badgeRow: some View {
        FlowRow(spacing: 8) {
            if state.isPinned {
                Button(action: onShowNext) {
                    HStack(spacing: 6) {
                        Circle().fill(theme.ink.opacity(0.6)).frame(width: 6, height: 6)
                        Text("Pinned · show next")
                            .grFont(10.5, .bold, style: .caption2, maxScale: 1.3)
                            .tracking(0.5)
                            .textCase(.uppercase)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityLabel("Pinned. Show the next train instead")
            }
            if view.cancelled {
                AlertBadge(tone: .cancel, text: "Cancelled")
            }
            if view.delayed && !view.cancelled {
                AlertBadge(tone: .delay, text: view.delayMinutes.map { "Delayed \($0)m" } ?? "Delayed")
            }
            if let change = view.trackChange {
                AlertBadge(tone: .track, text: "Track changed")
                    .id("\(change.from)-\(change.to)")
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                Text("Track \(change.from) → \(change.to)")
                    .grFont(11.8, .semibold, style: .footnote, digits: true)
                    .foregroundStyle(theme.ink.opacity(0.85))
            }
            if showsOnTime {
                OnTimeChip()
            }
        }
    }

    private var timeBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.time(view.expectedDeparture))
                .grFont(52.8, .semibold, style: .largeTitle, maxScale: 1.25, digits: true)
                .tracking(-1.3)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy, value: view.expectedDeparture)
            Text(state.riding ? Format.arrivalCountdown(view.expectedArrival, now: now) : Format.countdown(to: view.expectedDeparture, now: now))
                .grFont(16, .semibold, style: .headline, digits: true)
                .foregroundStyle(theme.ink.opacity(0.9))
                .contentTransition(.numericText())
            if showsOriginal {
                Text("Originally \(Format.time(trip.departure))")
                    .grFont(12.8, .medium, style: .subheadline, digits: true)
                    .foregroundStyle(theme.ink.opacity(0.75))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var trainLine: some View {
        var text = (trip.trainId.map { "Train \($0)" } ?? "Rail trip") + " to \(state.to.shortLabel)"
        if view.timing == nil, let arrival = view.expectedArrival {
            text += " · arrives \(Format.time(arrival))"
        }
        return Text(text)
            .grFont(13.1, style: .subheadline, digits: true)
            .foregroundStyle(theme.ink.opacity(0.85))
    }
}

/// One end of the journey. Each side reports its own lateness, because a
/// train can leave late and make some of it up before the destination.
struct LegCell: View {
    let label: String
    let station: String
    let leg: LegTiming
    @Environment(\.theme) private var theme

    var body: some View {
        let late = leg.delayMinutes > 0
        VStack(alignment: .leading, spacing: 0) {
            Text(label).kicker(9.9)
            Text(Format.time(leg.expected))
                .grFont(19.2, .semibold, style: .title3, maxScale: 1.4, digits: true)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(.snappy, value: leg.expected)
                .padding(.top, 4)
            Group {
                if late {
                    HStack(spacing: 4) {
                        Circle().fill(Accent.delay).frame(width: 6, height: 6)
                        Text("\(leg.delayMinutes)m late")
                            .grFont(9.9, .bold, style: .caption2, maxScale: 1.4, digits: true)
                            .tracking(0.5)
                            .textCase(.uppercase)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Accent.delay.opacity(0.2)))
                    .overlay(Capsule().strokeBorder(Accent.delay.opacity(0.55), lineWidth: 1))
                } else {
                    Text(leg.live ? "On time" : "Scheduled")
                        .grFont(10.2, .semibold, style: .caption2, maxScale: 1.4)
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.ink.opacity(0.6))
                }
            }
            .padding(.top, 6)
            Text(station)
                .grFont(10.9, style: .caption)
                .foregroundStyle(theme.ink.opacity(0.65))
                .lineLimit(1)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .insetPanel(radius: 12, highlight: late ? Accent.delay.opacity(0.5) : nil)
        .accessibilityElement(children: .combine)
    }
}

/// Service / Type / Track.
struct MetaChip: View {
    let label: String
    let value: String
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).kicker(9.6)
            Text(value)
                .grFont(13.1, .semibold, style: .footnote, maxScale: 1.4, digits: true)
                .tracking(-0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .insetPanel(radius: 12, highlight: highlight ? Accent.track.opacity(0.55) : nil)
        .accessibilityElement(children: .combine)
    }
}

/// When the connecting train picks the rider up at a transfer.
struct ConnectionRow: View {
    let connection: Connection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Connection at \(connection.station)").kicker(9.3)
                Text(connection.trainId.map { "Train \($0)" } ?? "Connecting train")
                    .grFont(12.5, .medium, style: .footnote, digits: true)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(connection.departure.map(Format.time) ?? "--")
                .grFont(15.2, .semibold, style: .headline, digits: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .insetPanel(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

/// "Past X · next Y"; opens the stops sheet.
struct PositionButton: View {
    let trainId: String?
    let label: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Train position").kicker(9.6)
                    Text(label)
                        .grFont(13.4, .medium, style: .footnote, digits: true)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .insetPanel(radius: 12)
        .accessibilityLabel("Where is train \(trainId ?? "")? \(label)")
        .accessibilityHint("Shows every stop")
    }
}

/// v4's `.press`: a quick scale on touch.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

/// Shown when the rider's own station has no trains at all: name the
/// situation and point at the nearest station that does have service.
struct NoServiceView: View {
    let state: BoardState
    let now: Date
    @Environment(\.theme) private var theme

    var body: some View {
        // Heading home, it is the destination that has no trains.
        let homebound = state.to.id == UserConfig.homeId
        let dead = homebound ? state.to : state.from
        let preposition = homebound ? "to" : "from"
        VStack(alignment: .leading, spacing: 0) {
            if state.noService {
                Text("No trains \(preposition) \(dead.shortLabel)")
                    .grFont(16.8, .semibold, style: .headline)
                    .padding(.top, 12)
                Text("NJ Transit is not running service \(preposition) this station right now.")
                    .grFont(12.8, style: .subheadline)
                    .foregroundStyle(theme.ink.opacity(0.78))
                    .padding(.top, 4)
                if let alternate = state.alternate {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nearest service · \(alternate.from.shortLabel) → \(alternate.to.shortLabel)").kicker(9.6)
                        ForEach(alternate.views, id: \.trip) { view in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text((view.trip.trainId.map { "Train \($0)" } ?? "Rail trip") + " · " + Format.transferLabel(view.trip.transferCount))
                                    .grFont(12.5, style: .footnote, digits: true)
                                    .foregroundStyle(theme.ink.opacity(0.85))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Format.time(view.expectedDeparture))
                                    .grFont(15.2, .semibold, style: .headline, digits: true)
                                Text(Format.countdown(to: view.expectedDeparture, now: now))
                                    .grFont(11.2, .medium, style: .caption, digits: true)
                                    .foregroundStyle(theme.ink.opacity(0.7))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .insetPanel(radius: 16)
                    .padding(.top, 12)
                } else {
                    Text("Nothing scheduled from nearby stations either. The \(state.commuteMode == .am ? "PM" : "AM") direction may still have service.")
                        .grFont(12.5, style: .footnote)
                        .foregroundStyle(theme.ink.opacity(0.7))
                        .padding(.top, 8)
                }
            } else {
                // Sample or stale data with nothing left this way.
                Text("No more trains this way")
                    .grFont(16.8, .semibold, style: .headline)
                    .padding(.top, 12)
                Text("Pull down to refresh.")
                    .grFont(12.8, style: .subheadline)
                    .foregroundStyle(theme.ink.opacity(0.78))
                    .padding(.top, 4)
            }
        }
    }
}

/// Wraps badges onto a second line when they don't fit (v4's flex-wrap).
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
