import GlassRailKit
import SwiftUI
import WidgetKit

@main
struct GlassRailWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextTrainWidget()
        RideLiveActivity()
    }
}

struct TrainEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let themeId: String?
}

/// The next train for the current direction (by clock, like the app), with a
/// live countdown to its true pickup time, its track and any delay.
struct NextTrainWidget: Widget {
    let kind = "NextTrain"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextTrainProvider()) { entry in
            NextTrainEntryView(entry: entry)
        }
        .configurationDisplayName("Next train")
        .description("The next NJ Transit train your way, with countdown, track and delay.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct NextTrainEntryView: View {
    let entry: TrainEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let theme = Theme.named(entry.themeId)
        TrainWidgetView(snapshot: entry.snapshot, family: family)
            .environment(\.theme, theme)
            .widgetURL(URL(string: "glassrail://board"))
            .containerBackground(for: .widget) {
                ThemeBackdrop(theme: theme)
            }
    }
}

struct NextTrainProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrainEntry {
        TrainEntry(date: Date(), snapshot: .preview(), themeId: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrainEntry) -> Void) {
        if context.isPreview {
            completion(TrainEntry(date: Date(), snapshot: .preview(), themeId: SharedStore(appGroup: SharedStore.appGroup()).themeId))
            return
        }
        Task {
            let data = await WidgetData.load(now: Date())
            let now = Date()
            completion(TrainEntry(
                date: now,
                snapshot: WidgetPlanner.snapshot(payload: data.payload, runs: data.runs, destinationId: data.destinationId, at: now),
                themeId: data.themeId
            ))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrainEntry>) -> Void) {
        Task {
            let now = Date()
            let data = await WidgetData.load(now: now)
            let snapshots = WidgetPlanner.timeline(payload: data.payload, runs: data.runs, destinationId: data.destinationId, now: now)
            let entries = snapshots.map { TrainEntry(date: $0.date, snapshot: $0, themeId: data.themeId) }
            let reload = WidgetPlanner.reloadDate(now: now, first: snapshots.first)
            completion(Timeline(entries: entries, policy: .after(reload)))
        }
    }
}

/// Where the widget's data comes from: the app's saved data when it is at
/// most 5 minutes old, otherwise NJ Transit directly (only the two directions
/// for the chosen terminal, two planner lookups each), otherwise the last
/// saved data, otherwise the bundled sample (labeled SAMPLE).
enum WidgetData {
    struct Loaded {
        var payload: Payload
        var runs: Runs
        var destinationId: String
        var themeId: String?
    }

    /// Saved data is still better than a sample within this window.
    static let fallbackWindow: TimeInterval = 6 * 3600

    static func load(now: Date) async -> Loaded {
        let store = SharedStore(appGroup: SharedStore.appGroup())
        let destinationId = store.destinationId
        let themeId = store.themeId
        let saved = store.snapshot

        if let saved, WidgetPlanner.canReuse(saved.payload, now: now) {
            return Loaded(payload: saved.payload, runs: saved.runs, destinationId: destinationId, themeId: themeId)
        }

        let client = NJTClient()
        do {
            let payload = try await client.fetchLivePayload(
                pairs: WidgetPlanner.pairs(destinationId: destinationId),
                plannerOffsets: WidgetPlanner.plannerOffsetsMinutes
            )
            let ids = WidgetPlanner.trainsNeedingStops(payload: payload, destinationId: destinationId, now: now)
            let runs = await client.fetchTrainRuns(ids)
            return Loaded(payload: payload, runs: runs, destinationId: destinationId, themeId: themeId)
        } catch {
            if let saved, saved.payload.source.kind == .live, now.timeIntervalSince(saved.payload.generatedAt) < fallbackWindow {
                return Loaded(payload: saved.payload, runs: saved.runs, destinationId: destinationId, themeId: themeId)
            }
            return Loaded(payload: SampleFixture.payload(now: now), runs: [:], destinationId: destinationId, themeId: themeId)
        }
    }
}
