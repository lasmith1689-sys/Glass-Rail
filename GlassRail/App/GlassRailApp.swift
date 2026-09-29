import SwiftUI

@main
struct GlassRailApp: App {
    @State private var model = BoardModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if LaunchOptions.widgetGallery {
                    WidgetGallery()
                } else {
                    BoardScreen()
                }
            }
            .environment(model)
            .environment(\.theme, model.theme)
            .preferredColorScheme(model.theme.scheme)
            .task { model.start() }
            .onOpenURL { _ in model.becameActive() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.becameActive() }
        }
    }
}
