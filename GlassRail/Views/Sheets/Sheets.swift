import GlassRailKit
import SwiftUI

/// v4's sheet header: kicker, title, close button.
struct SheetHeader: View {
    let kicker: String
    let title: String
    var count: Int?
    /// Shows a back button (a page inside the sheet).
    var onBack: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                GlassIconButton(systemImage: "chevron.left", label: "Back", size: 32, action: onBack)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(kicker).kicker()
                HStack(spacing: 6) {
                    Text(title)
                        .grFont(15.2, .semibold, style: .headline, maxScale: 1.4)
                        .lineLimit(1)
                    if let count {
                        Text("· \(count)")
                            .grFont(15.2, .medium, style: .headline, maxScale: 1.4, digits: true)
                            .foregroundStyle(theme.ink.opacity(0.75))
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            GlassIconButton(systemImage: "xmark", label: "Close", size: 32) { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.ink.opacity(0.08)).frame(height: 1)
        }
    }
}

// MARK: Later this way

/// Every later train this way. Tapping one pins it to the main card.
struct LaterSheet: View {
    @Environment(BoardModel.self) private var model
    /// "On a train that's already left?" is open.
    @State private var showingEarlier = LaunchOptions.sheet == "earlier"

    var body: some View {
        let state = model.state
        let later = state?.later ?? []
        VStack(spacing: 0) {
            SheetHeader(
                kicker: "Later this way",
                title: state.map { "\($0.from.shortLabel) → \($0.to.shortLabel)" } ?? "",
                count: later.count
            )
            ScrollView {
                LazyVStack(spacing: 2) {
                    EarlierToggle(expanded: showingEarlier) {
                        withAnimation(.snappy) { showingEarlier.toggle() }
                    }
                    if showingEarlier {
                        EarlierRides(
                            rides: state?.recentRides ?? [],
                            loading: model.loadingRecentRides,
                            now: model.now,
                            onFollow: { model.pinTrip($0) }
                        )
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                    ForEach(later, id: \.trip) { view in
                        LaterRow(view: view, now: model.now) { model.pinTrip(view) }
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    if later.isEmpty {
                        Text("Nothing later.")
                            .grFont(13.1, style: .subheadline)
                            .opacity(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
        .task(id: showingEarlier) {
            // Opening it asks NJ Transit for the last hour's trains this way;
            // the ones remembered from earlier refreshes show straight away.
            if showingEarlier { await model.loadRecentRides() }
        }
    }
}

/// The quiet way in, at the top of the Later sheet, for a rider who boarded
/// without pinning: "On a train that's already left?"
struct EarlierToggle: View {
    let expanded: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.6))
                    .accessibilityHidden(true)
                Text("On a train that's already left?")
                    .grFont(12.5, .medium, style: .footnote, maxScale: 1.4)
                    .foregroundStyle(theme.ink.opacity(0.72))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.5))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityLabel("On a train that's already left?")
        .accessibilityValue(expanded ? "Showing trains that left in the last hour" : "")
        .accessibilityHint(expanded ? "Hides them" : "Shows trains this way that left in the last hour, to follow yours")
    }
}

/// Trains this way that left in the last hour and are still under way,
/// most recent first. Tapping one follows it on the main card, Live Activity
/// and all, as if it had been pinned before it left.
struct EarlierRides: View {
    let rides: [TripView]
    let loading: Bool
    let now: Date
    let onFollow: (TripView) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 2) {
            Text("Left in the last hour").kicker()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(rides, id: \.trip) { view in
                EarlierRideRow(view: view, now: now) { onFollow(view) }
            }
            if rides.isEmpty {
                HStack(spacing: 8) {
                    if loading {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking NJ Transit")
                    } else {
                        Text("No train this way left in the last hour.")
                    }
                }
                .grFont(12.5, style: .footnote, maxScale: 1.4)
                .foregroundStyle(theme.ink.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Rectangle()
                .fill(theme.ink.opacity(0.12))
                .frame(height: 0.5)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
        }
    }
}

/// One train that already left: when it left, and when it gets in.
struct EarlierRideRow: View {
    let view: TripView
    let now: Date
    let onFollow: () -> Void
    @Environment(\.theme) private var theme

    private var trip: Trip { view.trip }

    var body: some View {
        Button(action: onFollow) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.time(view.expectedDeparture))
                        .grFont(16, .semibold, style: .headline, maxScale: 1.4, digits: true)
                    Text(leftAgo)
                        .grFont(11.2, style: .caption, maxScale: 1.4, digits: true)
                        .foregroundStyle(theme.ink.opacity(0.72))
                }
                .frame(minWidth: 62, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(trip.trainId.map { "Train \($0)" } ?? "Rail trip")
                        Text(" · \(Format.tripType(trip))")
                            .foregroundStyle(theme.ink.opacity(0.8))
                    }
                    .grFont(13.1, .medium, style: .subheadline, maxScale: 1.4, digits: true)
                    .lineLimit(1)
                    if let arrival = view.expectedArrival {
                        Text("Arrives \(Format.time(arrival)) · \(Format.countdown(to: arrival, now: now).lowercased())")
                            .grFont(11.5, style: .caption, maxScale: 1.4, digits: true)
                            .foregroundStyle(theme.ink.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .pillSurface()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Follows this train on the main card")
    }

    /// "Left 12 min ago".
    private var leftAgo: String {
        let minutes = max(0, Int(now.timeIntervalSince(view.expectedDeparture) / 60))
        return minutes < 1 ? "Just left" : "Left \(minutes) min ago"
    }

    private var accessibilityText: String {
        var text = "Train \(trip.trainId ?? "trip"), left \(Format.time(view.expectedDeparture))"
        if let arrival = view.expectedArrival { text += ", arrives \(Format.time(arrival))" }
        return text
    }
}

struct LaterRow: View {
    let view: TripView
    let now: Date
    let onPin: () -> Void
    @Environment(\.theme) private var theme

    private var trip: Trip { view.trip }
    private var dropoffLate: Int { view.timing?.dropoff?.delayMinutes ?? 0 }
    private var hasAlert: Bool { view.delayed || view.cancelled || view.trackChange != nil }
    /// NJ Transit's own words when the badge can't say it all, as on the hero
    /// card: "This train is now departing from Hoboken".
    private var rawNote: String? {
        guard let note = trip.statusNote, !note.isEmpty,
              view.cancelled || (view.delayed && view.delayMinutes == nil) else { return nil }
        return note
    }

    var body: some View {
        Button(action: onPin) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.time(view.expectedDeparture))
                        .grFont(16, .semibold, style: .headline, maxScale: 1.4, digits: true)
                    Text(Format.countdown(to: view.expectedDeparture, now: now))
                        .grFont(11.2, style: .caption, maxScale: 1.4, digits: true)
                        .foregroundStyle(theme.ink.opacity(0.72))
                }
                .frame(minWidth: 62, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(trip.trainId.map { "Train \($0)" } ?? "Rail trip")
                        Text(" · \(Format.tripType(trip))")
                            .foregroundStyle(theme.ink.opacity(0.8))
                    }
                    .grFont(13.1, .medium, style: .subheadline, maxScale: 1.4, digits: true)
                    .lineLimit(1)
                    if view.expectedArrival != nil || !trip.transferAt.isEmpty {
                        detailLine
                            .grFont(11.5, style: .caption, maxScale: 1.4, digits: true)
                            .foregroundStyle(theme.ink.opacity(0.75))
                            .lineLimit(1)
                    }
                    if hasAlert {
                        FlowRow(spacing: 6) {
                            if view.cancelled {
                                AlertBadge(tone: .cancel, text: "Cancelled")
                            }
                            if view.delayed && !view.cancelled {
                                AlertBadge(tone: .delay, text: view.delayMinutes.map { "Delayed \($0)m" } ?? "Delayed")
                            }
                            if let change = view.trackChange {
                                AlertBadge(tone: .track, text: "Tk \(change.from) → \(change.to)")
                            }
                        }
                        .padding(.top, 4)
                    }
                    if let rawNote {
                        Text(rawNote)
                            .grFont(11.5, style: .caption, maxScale: 1.4)
                            .foregroundStyle(theme.ink.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(trip.track.map { "Tk \($0)" } ?? "--")
                    .grFont(12.5, .semibold, style: .footnote, maxScale: 1.4, digits: true)
                    .foregroundStyle(theme.ink.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .disabled(view.key == nil)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(view.key == nil ? "" : "Shows this train on the main card")
    }

    @ViewBuilder
    private var detailLine: some View {
        HStack(spacing: 0) {
            if let arrival = view.expectedArrival {
                Text("Arrives \(Format.time(arrival))")
                if dropoffLate > 0 {
                    Text(" · \(dropoffLate)m late")
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.lateText)
                }
                if !trip.transferAt.isEmpty {
                    Text(" · ")
                }
            }
            if !trip.transferAt.isEmpty {
                Text("via \(trip.transferAt.listed)")
            }
        }
    }

    private var accessibilityText: String {
        var text = "Train \(trip.trainId ?? "trip"), departs \(Format.time(view.expectedDeparture))"
        if let arrival = view.expectedArrival { text += ", arrives \(Format.time(arrival))" }
        if view.delayed, let minutes = view.delayMinutes { text += ", delayed \(minutes) minutes" }
        if view.cancelled { text += ", cancelled" }
        if let track = trip.track { text += ", track \(track)" }
        return text
    }
}

/// A row highlight on touch, like v4's hover/press tint.
struct RowPress: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.ink.opacity(configuration.isPressed ? 0.10 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

// MARK: Stops

/// Every stop of the featured train: past stops dimmed, the next one
/// highlighted, the rider's boarding and exit stops tagged.
struct StopsSheet: View {
    @Environment(BoardModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let state = model.state
        let stops = state?.heroStops ?? []
        let ahead = Journey.upcomingStops(stops).count
        let nextIndex = Journey.nextStopIndex(stops)
        VStack(spacing: 0) {
            SheetHeader(
                kicker: "Train \(state?.hero?.trip.trainId ?? "--") · all stops",
                title: ahead > 0 ? "\(ahead) stop\(ahead == 1 ? "" : "s") ahead" : "Run complete"
            )
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                        StopRow(
                            stop: stop,
                            isNext: index == nextIndex,
                            isBoard: state.map { Journey.stopMatchesStation(stop.name, $0.from.ref) } ?? false,
                            isExit: state.map { Journey.stopMatchesStation(stop.name, $0.to.ref) } ?? false
                        )
                    }
                    if stops.isEmpty {
                        Text("No stop data for this train yet.")
                            .grFont(13.1, style: .subheadline)
                            .foregroundStyle(theme.ink.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: Service alerts

/// NJ Transit's travel alerts for the lines through Watchung Avenue, in full,
/// in NJ Transit's order.
struct AlertsSheet: View {
    @Environment(BoardModel.self) private var model
    @Environment(\.theme) private var theme

    private var red: Color { theme.scheme == .light ? Color(hex: 0xB91C1C) : Accent.cancel }

    var body: some View {
        let alerts = model.state?.serviceAlerts ?? []
        VStack(spacing: 0) {
            SheetHeader(
                kicker: "NJ Transit",
                title: alerts.count == 1 ? "Service alert" : "Service alerts",
                count: alerts.count > 1 ? alerts.count : nil
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(alerts.enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(red)
                                .padding(.top, 2)
                                .accessibilityHidden(true)
                            Text(text)
                                .grFont(14, style: .subheadline)
                                .foregroundStyle(theme.ink.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .insetPanel(radius: 16)
                    }
                    Text(alerts.isEmpty
                         ? "No alerts for the Montclair-Boonton or Montclair lines right now."
                         : "For the Montclair-Boonton and Montclair lines, from NJ Transit.")
                        .grFont(11.5, style: .caption)
                        .foregroundStyle(theme.ink.opacity(0.7))
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct StopRow: View {
    let stop: TrainStop
    let isNext: Bool
    let isBoard: Bool
    let isExit: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if stop.departed {
                    Circle().fill(theme.ink.opacity(0.4))
                } else if isNext {
                    Circle().fill(Accent.track)
                } else {
                    Circle().strokeBorder(theme.ink.opacity(0.45), lineWidth: 1)
                }
            }
            .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stop.name)
                        .grFont(13.1, .medium, style: .subheadline, maxScale: 1.4)
                        .lineLimit(1)
                    if isNext { tag("Next", color: Accent.track) }
                    if isBoard { tag("Board", color: theme.ink.opacity(0.6)) }
                    if isExit { tag("Your stop", color: theme.ink.opacity(0.6)) }
                }
                if let note = stop.note {
                    Text(note)
                        .grFont(10.9, style: .caption, maxScale: 1.4)
                        .foregroundStyle(theme.ink.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(stop.time.map(Format.time) ?? "--")
                .grFont(12.5, .semibold, style: .footnote, maxScale: 1.4, digits: true)
                .foregroundStyle(theme.ink.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.ink.opacity(isNext ? 0.08 : 0))
        )
        .opacity(stop.departed ? 0.45 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stop.departed ? "Departed" : (isNext ? "Next stop" : ""))
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .grFont(9, .bold, style: .caption2, maxScale: 1.3)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

// MARK: Settings

/// "Choose a look": v4's five themes.
struct SettingsSheet: View {
    @Environment(BoardModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var choosingHome = LaunchOptions.sheet == "home"

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        if choosingHome {
            HomeStationPicker(
                currentId: model.homeId,
                onChoose: { id in model.selectHome(id) },
                onBack: { withAnimation(.snappy) { choosingHome = false } }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            settings
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            SheetHeader(kicker: "Glass Rail", title: "Settings")
            ScrollView {
                Text("Home station").kicker()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                HomeStationRow(station: model.home) {
                    withAnimation(.snappy) { choosingHome = true }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                Text("Choose a look").kicker()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Theme.all) { option in
                        ThemeTile(option: option, active: option.id == theme.id) {
                            model.selectTheme(option)
                        }
                    }
                }
                .padding(12)
                Text("The widgets use the same look.")
                    .grFont(11.5, style: .caption)
                    .foregroundStyle(theme.ink.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// The home station in Settings: where every trip starts or ends.
struct HomeStationRow: View {
    let station: Station
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(station.name)
                            .grFont(15.2, .semibold, style: .headline, maxScale: 1.4)
                        if station.id == UserConfig.defaultHomeId {
                            DefaultPill()
                        }
                    }
                    Text(station.lineTitles.joined(separator: " · "))
                        .grFont(11.5, style: .caption, maxScale: 1.4)
                        .foregroundStyle(theme.ink.opacity(0.75))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text("Change")
                    .grFont(12.5, .semibold, style: .footnote, maxScale: 1.4)
                    .foregroundStyle(theme.ink.opacity(0.85))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.6))
            }
            .padding(14)
            .contentShape(Rectangle())
            .insetPanel(radius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Home station, \(station.name)")
        .accessibilityHint("Choose another station")
    }
}

/// "Default" beside Watchung Avenue, in Settings and the station picker.
struct DefaultPill: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Default")
            .grFont(10, .bold, style: .caption2, maxScale: 1.3)
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(theme.ink.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .pillSurface()
    }
}

/// Any NJ Transit rail station as home, Watchung Avenue first (the default).
struct HomeStationPicker: View {
    let currentId: String
    let onChoose: (String) -> Void
    let onBack: () -> Void
    @State private var query = ""
    @Environment(\.theme) private var theme

    private var stations: [Station] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let all = Stations.homeChoices.filter { $0.id == UserConfig.defaultHomeId }
            + Stations.homeChoices.filter { $0.id != UserConfig.defaultHomeId }
        guard !words.isEmpty else { return all }
        return all.filter { station in
            let text = "\(station.name) \(station.plannerName) \(station.lineTitles.joined(separator: " "))".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(kicker: "Settings", title: "Home station", onBack: onBack)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.6))
                    .accessibilityHidden(true)
                TextField("Search stations or lines", text: $query)
                    .grFont(14, style: .subheadline)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .insetPanel(radius: 14)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(stations) { station in
                        Button {
                            onChoose(station.id)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(station.name)
                                            .grFont(14.4, .semibold, style: .subheadline, maxScale: 1.4)
                                        if station.id == UserConfig.defaultHomeId {
                                            DefaultPill()
                                        }
                                    }
                                    Text(station.lineTitles.joined(separator: " · "))
                                        .grFont(11.5, style: .caption, maxScale: 1.4)
                                        .foregroundStyle(theme.ink.opacity(0.7))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if station.id == currentId {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color(hex: 0x059669))
                                        .accessibilityLabel("Current")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowPress())
                    }
                    if stations.isEmpty {
                        Text("No NJ Transit rail station matches “\(query)”.")
                            .grFont(13.1, style: .subheadline)
                            .foregroundStyle(theme.ink.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    Text("Trips run between your station and Hoboken or Penn Station NY. The widgets follow it.")
                        .grFont(11.5, style: .caption)
                        .foregroundStyle(theme.ink.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }
}

struct ThemeTile: View {
    let option: Theme
    let active: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    ThemeBackdrop(theme: option, showsCard: false)
                        .overlay {
                            GeometryReader { proxy in
                                let w = proxy.size.width
                                let h = proxy.size.height
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LinearGradient(colors: [option.cardTop, option.cardBottom], startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(option.insetBorder, lineWidth: 1))
                                    .frame(width: w * 0.72, height: h * 0.36)
                                    .position(x: w / 2, y: h * 0.22 + h * 0.18)
                                Capsule()
                                    .fill(LinearGradient(colors: option.shimmer, startPoint: .leading, endPoint: .trailing))
                                    .frame(width: w * 0.56, height: max(3, h * 0.05))
                                    .opacity(0.85)
                                    .position(x: w / 2, y: h * 0.75)
                            }
                        }
                        .frame(height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(option.insetBorder, lineWidth: 1))
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 10)
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(hex: 0x059669))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white))
                            .shadow(radius: 3)
                            .padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .grFont(13.8, .semibold, style: .subheadline, maxScale: 1.4)
                    Text(option.tagline)
                        .grFont(11.2, style: .caption, maxScale: 1.4)
                        .foregroundStyle(theme.ink.opacity(0.75))
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.ink.opacity(active ? 0.05 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.ink.opacity(active ? 0.35 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("\(option.label) theme, \(option.tagline)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
