import GlassRailKit
import SwiftUI

/// The one screen, laid out like v4: header, route bar, hero, "Later this
/// way" pinned to the bottom of the pane, footer. The middle scrolls only on a
/// short screen or at large text sizes, and pulls to refresh.
struct BoardScreen: View {
    @Environment(BoardModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var refreshing = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            ThemeBackdrop(theme: theme, lively: true)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HeaderBar(
                    feedMode: model.state?.feedMode,
                    generatedAt: model.dataUpdatedAt,
                    now: model.now,
                    alertCount: model.state?.serviceAlerts.count ?? 0,
                    onShowAlerts: { model.activeSheet = .alerts }
                )
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            if let state = model.state {
                                RouteBar(
                                    state: state,
                                    destinationId: model.destinationId,
                                    isOverridden: model.modeOverride != nil,
                                    onFlip: model.flipDirection,
                                    onSelectDestination: model.selectDestination
                                )
                                HeroCard(
                                    state: state,
                                    now: model.now,
                                    departedLabel: model.visibleDepartedLabel,
                                    departedFading: model.departedFading,
                                    onShowNext: model.unpin,
                                    onOpenStops: { model.activeSheet = .stops }
                                )
                                Spacer(minLength: 0)
                                LaterTeaser(later: state.later) { model.activeSheet = .later }
                            } else {
                                LoadingCard()
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 12)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await model.refresh() }
                }
                FooterBar(
                    generatedAt: model.dataUpdatedAt,
                    now: model.now,
                    refreshing: refreshing,
                    onRefresh: {
                        guard !refreshing else { return }
                        refreshing = true
                        Task {
                            await model.refresh()
                            refreshing = false
                        }
                    },
                    onSettings: { model.activeSheet = .settings }
                )
            }
        }
        .foregroundStyle(theme.ink)
        .animation(.snappy, value: model.state?.hero?.key)
        .sensoryFeedback(.selection, trigger: model.destinationId)
        .sensoryFeedback(.selection, trigger: model.modeOverride)
        .sensoryFeedback(.impact(weight: .light), trigger: model.pin)
        .sensoryFeedback(.success, trigger: model.refreshCount)
        .sheet(item: $model.activeSheet) { sheet in
            Group {
                switch sheet {
                case .later:
                    LaterSheet()
                        .presentationDetents([.fraction(0.62), .large])
                case .stops:
                    StopsSheet()
                        .presentationDetents([.fraction(0.72), .large])
                case .settings:
                    SettingsSheet()
                        .presentationDetents([.fraction(0.62), .large])
                case .alerts:
                    AlertsSheet()
                        .presentationDetents([.fraction(0.62), .large])
                }
            }
            .environment(model)
            .environment(\.theme, theme)
            .foregroundStyle(theme.ink)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }
}

/// First launch with nothing saved yet: a brief wait for NJ Transit.
private struct LoadingCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your ride").kicker()
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking NJ Transit")
                    .grFont(15.7, .semibold, style: .headline)
            }
            Text("Live departures for Watchung Ave, Hoboken and Penn Station NY.")
                .grFont(12.5, style: .footnote)
                .foregroundStyle(theme.ink.opacity(0.75))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 24)
    }
}
