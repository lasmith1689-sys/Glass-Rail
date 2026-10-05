import GlassRailKit
import SwiftUI
import WidgetKit

/// Widget layouts. Compiled into the widget extension and into the app (which
/// can show them in a debug gallery for CI screenshots).
struct TrainWidgetView: View {
    let snapshot: WidgetSnapshot
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .systemMedium:
            MediumTrainWidget(snapshot: snapshot)
        case .accessoryRectangular:
            RectangularTrainWidget(snapshot: snapshot)
        case .accessoryInline:
            InlineTrainWidget(snapshot: snapshot)
        default:
            SmallTrainWidget(snapshot: snapshot)
        }
    }
}

enum WidgetText {
    /// "10:43" and "AM", so the clock can be big and the meridiem small.
    static func clock(_ date: Date) -> (time: String, meridiem: String) {
        let parts = Format.time(date).split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    static func route(_ snapshot: WidgetSnapshot) -> String {
        "\(snapshot.from.code ?? snapshot.from.shortLabel) → \(snapshot.to.code ?? snapshot.to.shortLabel)"
    }

    /// A widget-sized station name ("Watchung", "Penn Station").
    static func name(_ station: Station) -> String {
        switch station.id {
        case "watchung": return "Watchung"
        case "penn": return "Penn Station"
        default: return station.shortLabel
        }
    }

    /// "To Hoboken": all a small widget needs to say about the direction.
    static func heading(_ snapshot: WidgetSnapshot) -> String {
        "To \(name(snapshot.to))"
    }

    static func status(_ train: WidgetTrain) -> (text: String, tone: AlertBadge.Tone)? {
        if train.cancelled { return ("Cancelled", .cancel) }
        // Not the widget's destination today: worth more than a delay.
        if let terminus = train.terminus { return ("To \(terminus)", .delay) }
        if train.delayed { return (train.delayMinutes.map { "Delayed \($0)m" } ?? "Delayed", .delay) }
        return nil
    }

    /// "+6m" or "Cancelled", for the tightest layouts.
    static func shortStatus(_ train: WidgetTrain) -> String? {
        if train.cancelled { return "Cancelled" }
        if let terminus = train.terminus { return "To \(terminus)" }
        if train.delayed { return train.delayMinutes.map { "+\($0)m" } ?? "Late" }
        return nil
    }

    static func track(_ train: WidgetTrain) -> String {
        train.track.map { "Tk \($0)" } ?? "Tk --"
    }

    /// What to say with no train to show: no service, none left, or (when NJ
    /// Transit never answered for this direction) that nothing loaded.
    static func noTrain(_ snapshot: WidgetSnapshot, noService: String, noneLeft: String, unanswered: String) -> String {
        if snapshot.noService { return noService }
        return snapshot.unanswered ? unanswered : noneLeft
    }
}

/// Counts down to the (true) departure and stops at 0:00.
struct DepartureCountdown: View {
    let from: Date
    let departure: Date
    var prefix: String?

    var body: some View {
        if departure > from {
            HStack(spacing: 4) {
                if let prefix { Text(prefix) }
                Text(timerInterval: from...departure, countsDown: true, showsHours: true)
            }
        } else {
            Text("Now")
        }
    }
}

struct SmallTrainWidget: View {
    let snapshot: WidgetSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(WidgetText.heading(snapshot))
                    .font(theme.font(size: 10, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.ink.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if snapshot.isSample {
                    SampleMark()
                } else if snapshot.feedMode == .stale, let updated = snapshot.updatedAt {
                    StaleMark(updated: updated)
                }
            }
            Spacer(minLength: 4)
            if let train = snapshot.next {
                let clock = WidgetText.clock(train.departure)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(clock.time)
                        .font(theme.font(size: 36, weight: .semibold).monospacedDigit())
                        .tracking(-1)
                        .widgetAccentable()
                    Text(clock.meridiem)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.75))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                DepartureCountdown(from: snapshot.date, departure: train.departure, prefix: "in")
                    .font(theme.font(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.ink.opacity(0.9))
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    if let status = WidgetText.status(train) {
                        WidgetBadge(text: status.text, tone: status.tone)
                    } else {
                        Text(train.trainId.map { "#\($0)" } ?? "")
                            .font(theme.font(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(theme.ink.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                    Text(WidgetText.track(train))
                        .font(theme.font(size: 13, weight: .bold).monospacedDigit())
                }
            } else {
                NoTrainWidgetText(snapshot: snapshot)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(theme.ink)
    }
}

struct MediumTrainWidget: View {
    let snapshot: WidgetSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SmallTrainWidget(snapshot: snapshot)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(theme.ink.opacity(0.12))
                .frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Later this way")
                    .font(theme.font(size: 10, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.ink.opacity(0.7))
                    .lineLimit(1)
                if snapshot.later.isEmpty {
                    Text(snapshot.next == nil ? "" : "Nothing later.")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.ink.opacity(0.7))
                } else {
                    ForEach(Array(snapshot.later.prefix(3).enumerated()), id: \.offset) { _, train in
                        LaterWidgetRow(train: train)
                    }
                }
                Spacer(minLength: 0)
                Text(snapshot.updatedAt.map { "Updated \(Format.time($0))" } ?? "Not updated")
                    .font(theme.font(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.ink.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.ink)
    }
}

struct LaterWidgetRow: View {
    let train: WidgetTrain
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(Format.time(train.departure))
                .font(theme.font(size: 14, weight: .semibold).monospacedDigit())
                .lineLimit(1)
            if train.cancelled {
                Circle().fill(Accent.cancel).frame(width: 6, height: 6)
            } else if train.delayed {
                Text(train.delayMinutes.map { "+\($0)m" } ?? "late")
                    .font(theme.font(size: 10, weight: .heavy).monospacedDigit())
                    .foregroundStyle(theme.lateText)
            }
            Spacer(minLength: 0)
            Text(WidgetText.track(train))
                .font(theme.font(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.ink.opacity(0.8))
        }
    }
}

struct RectangularTrainWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label {
                Text("\(WidgetText.name(snapshot.from)) → \(WidgetText.name(snapshot.to))")
            } icon: {
                Image(systemName: "tram.fill")
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .widgetAccentable()
            if let train = snapshot.next {
                Text("\(Format.time(train.departure)) · \(WidgetText.track(train))")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    if train.departure > snapshot.date {
                        DepartureCountdown(from: snapshot.date, departure: train.departure, prefix: "Leaves in")
                    } else {
                        Text("Leaving now")
                    }
                    Spacer(minLength: 4)
                    if let status = WidgetText.shortStatus(train) {
                        Text(status).fontWeight(.bold)
                    }
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                Text(WidgetText.noTrain(snapshot, noService: "No trains right now", noneLeft: "No more trains", unanswered: "Trains not loaded"))
                    .font(.system(size: 13, weight: .semibold))
                if let alt = snapshot.alternateNext, let from = snapshot.alternateFrom {
                    Text("\(from.shortLabel) \(Format.time(alt.departure))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InlineTrainWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if let train = snapshot.next {
            Label {
                Text(train.inlineSummary)
            } icon: {
                Image(systemName: "tram.fill")
            }
        } else {
            Label(WidgetText.noTrain(snapshot, noService: "No trains now", noneLeft: "No more trains", unanswered: "Not loaded"), systemImage: "tram")
        }
    }
}

struct NoTrainWidgetText: View {
    let snapshot: WidgetSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(WidgetText.noTrain(snapshot, noService: "No trains", noneLeft: "No more trains", unanswered: "Not loaded"))
                .font(theme.font(size: 17, weight: .semibold))
            if let alt = snapshot.alternateNext, let from = snapshot.alternateFrom {
                Text("Nearest: \(from.shortLabel)")
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.ink.opacity(0.75))
                Text(Format.time(alt.departure))
                    .font(theme.font(size: 15, weight: .semibold).monospacedDigit())
            } else {
                Text("Open Glass Rail for details.")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.ink.opacity(0.75))
            }
        }
    }
}

struct WidgetBadge: View {
    let text: String
    let tone: AlertBadge.Tone

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tone.accent).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9, weight: .heavy).monospacedDigit())
                .tracking(0.6)
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.accent.opacity(0.22)))
        .overlay(Capsule().strokeBorder(tone.accent.opacity(0.55), lineWidth: 1))
    }
}

struct SampleMark: View {
    var body: some View {
        Text("Sample")
            .font(.system(size: 8, weight: .heavy))
            .tracking(0.6)
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Accent.delay.opacity(0.25)))
    }
}

extension WidgetSnapshot {
    /// A believable board for previews and the widget gallery.
    static func preview(now: Date = Date(), destinationId: String = "hoboken") -> WidgetSnapshot {
        let payload = Demo.payload(.delayed, step: 0, now: now.addingTimeInterval(-30 * 60))
        return WidgetPlanner.snapshot(
            payload: payload,
            runs: Demo.runs(for: payload, now: now),
            destinationId: destinationId,
            at: now,
            modeOverride: ModeOverride(mode: .am, at: now)
        )
    }
}

/// Old data on a small widget: when the trains were last fetched, so a stale
/// board never passes for a live one.
struct StaleMark: View {
    let updated: Date
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "clock.arrow.circlepath")
            Text(Format.time(updated))
        }
        .font(.system(size: 9, weight: .semibold).monospacedDigit())
        .foregroundStyle(theme.lateText)
        .lineLimit(1)
        .accessibilityLabel("Last updated \(Format.time(updated))")
    }
}
