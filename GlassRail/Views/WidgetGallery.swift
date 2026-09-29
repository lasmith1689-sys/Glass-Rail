import GlassRailKit
import SwiftUI
import WidgetKit

/// Debug-only (`-GlassRailWidgetGallery YES`): renders the widget layouts at
/// their iPhone sizes, and the Live Activity's Lock Screen layout, so CI can
/// screenshot them. Uses the board's current data, or a QA scenario.
struct WidgetGallery: View {
    @Environment(BoardModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let snapshot = gallerySnapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Glass Rail widgets").kicker()
                HStack(alignment: .top, spacing: 16) {
                    tile(.systemSmall, snapshot: snapshot)
                    VStack(alignment: .leading, spacing: 10) {
                        lockTile(.accessoryRectangular, snapshot: snapshot)
                        lockTile(.accessoryInline, snapshot: snapshot)
                    }
                }
                tile(.systemMedium, snapshot: snapshot)
                if let state = model.state,
                   let ride = RideActivityAttributes.preview(state: state, updatedAt: model.payload?.generatedAt ?? model.now, now: model.now) {
                    Text("Live Activity").kicker()
                    RideLockScreenView(attributes: ride.0, state: ride.1)
                        .frame(width: 364, alignment: .leading)
                        .background(Color(hex: 0x15203A).opacity(0.72))
                        .background(ThemeBackdrop(theme: theme))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .environment(\.colorScheme, .dark)
                }
            }
            .padding(20)
        }
        .background(ThemeBackdrop(theme: .glass, showsCard: false).ignoresSafeArea())
    }

    private var gallerySnapshot: WidgetSnapshot {
        guard let payload = model.payload else { return .preview(now: model.now) }
        return WidgetPlanner.snapshot(
            payload: payload,
            runs: model.runs,
            destinationId: model.destinationId,
            at: model.now,
            modeOverride: model.demo != nil ? ModeOverride(mode: .am, at: model.now) : nil
        )
    }

    private func size(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemMedium: return CGSize(width: 364, height: 170)
        case .accessoryRectangular: return CGSize(width: 172, height: 76)
        case .accessoryInline: return CGSize(width: 172, height: 26)
        default: return CGSize(width: 170, height: 170)
        }
    }

    private func tile(_ family: WidgetFamily, snapshot: WidgetSnapshot) -> some View {
        let frame = size(family)
        return TrainWidgetView(snapshot: snapshot, family: family)
            .padding(16)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .background(ThemeBackdrop(theme: theme))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
    }

    private func lockTile(_ family: WidgetFamily, snapshot: WidgetSnapshot) -> some View {
        let frame = size(family)
        return TrainWidgetView(snapshot: snapshot, family: family)
            .foregroundStyle(.white)
            .frame(width: frame.width, height: frame.height, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.35)))
            .environment(\.colorScheme, .dark)
    }
}
