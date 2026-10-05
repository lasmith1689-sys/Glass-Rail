import Foundation
import GlassRailKit

/// Debug launch arguments (read from the argument domain, e.g.
/// `-GlassRailDemo delayed`). CI's Simulator smoke test uses them to render
/// v4's QA scenarios, open a sheet, or show the widget gallery.
enum LaunchOptions {
    private static var defaults: UserDefaults { .standard }

    /// v4's `?demo=` scenarios.
    static var demo: DemoScenario? {
        DemoScenario.parse(defaults.string(forKey: "GlassRailDemo"))
    }

    /// Open this sheet on launch: `later`, `stops`, `settings`, `alerts`,
    /// `home` (Settings at its home station picker), or `earlier` (the Later
    /// sheet with "On a train that's already left?" open).
    static var sheet: String? {
        defaults.string(forKey: "GlassRailSheet")
    }

    /// Give a QA scenario two NJ Transit travel alerts, so the smoke test can
    /// show the header's alert link and the alerts sheet whatever NJ Transit
    /// is reporting that day.
    static var alerts: Bool {
        defaults.bool(forKey: "GlassRailAlerts")
    }

    /// Show the widget layouts inside the app, for screenshots.
    static var widgetGallery: Bool {
        defaults.bool(forKey: "GlassRailWidgetGallery")
    }

    /// Force a theme for this launch without saving it.
    static var theme: String? {
        defaults.string(forKey: "GlassRailTheme")
    }
}
