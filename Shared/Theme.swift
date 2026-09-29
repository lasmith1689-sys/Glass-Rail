import SwiftUI

/// v4's five looks (app/globals.css), as color tokens. The app and the widget
/// both read these, so a widget matches the theme picked in Settings.
struct Theme: Identifiable, Equatable {
    struct Glow: Equatable {
        /// Where the radial glow is centered (CSS `circle at x% y%`).
        var center: UnitPoint
        var color: Color
        /// Radius as a fraction of the distance to the farthest corner.
        var reach: CGFloat
    }

    let id: String
    let label: String
    let tagline: String
    /// Text color. Dark on the light themes, light on the dark ones.
    let ink: Color
    let scheme: ColorScheme
    let base: [Gradient.Stop]
    let baseStart: UnitPoint
    let baseEnd: UnitPoint
    let glows: [Glow]
    let cardTop: Color
    let cardBottom: Color
    let insetTop: Color
    let insetBottom: Color
    let insetBorder: Color
    let pillTop: Color
    let pillBottom: Color
    let pillBorder: Color
    let divider: Color
    let shimmer: [Color]
    let routeGlow: Color
    /// Inline lateness text ("6m late"), readable on this theme's card.
    let lateText: Color

    static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }

    static let all: [Theme] = [.glass, .midnight, .aurora, .sunset, .liquid]

    static func named(_ id: String?) -> Theme {
        all.first { $0.id == id } ?? .glass
    }

    // MARK: Tokens

    /// CSS `linear-gradient(160deg, ...)`.
    private static let deg160 = (UnitPoint(x: 0.33, y: 0), UnitPoint(x: 0.67, y: 1))
    /// CSS `linear-gradient(165deg, ...)`.
    private static let deg165 = (UnitPoint(x: 0.37, y: 0), UnitPoint(x: 0.63, y: 1))

    static let glass = Theme(
        id: "glass",
        label: "Glass",
        tagline: "Default · midnight blue",
        ink: Color(hex: 0x101A28),
        scheme: .light,
        base: [.init(color: Color(hex: 0x2A3A5E), location: 0), .init(color: Color(hex: 0x1D2A48), location: 0.38), .init(color: Color(hex: 0x15203A), location: 1)],
        baseStart: deg160.0,
        baseEnd: deg160.1,
        glows: [
            Glow(center: UnitPoint(x: 0.12, y: 0.06), color: Color(r: 98, g: 138, b: 220, a: 0.55), reach: 0.30),
            Glow(center: UnitPoint(x: 0.88, y: 0.18), color: Color(r: 255, g: 255, b: 255, a: 0.18), reach: 0.22),
            Glow(center: UnitPoint(x: 0.78, y: 0.88), color: Color(r: 192, g: 152, b: 90, a: 0.40), reach: 0.32),
            Glow(center: UnitPoint(x: 0.14, y: 0.78), color: Color(r: 82, g: 110, b: 168, a: 0.35), reach: 0.28),
        ],
        cardTop: Color(r: 252, g: 254, b: 255, a: 0.72),
        cardBottom: Color(r: 212, g: 225, b: 245, a: 0.52),
        insetTop: Color(r: 255, g: 255, b: 255, a: 0.58),
        insetBottom: Color(r: 204, g: 218, b: 240, a: 0.38),
        insetBorder: Color(r: 255, g: 255, b: 255, a: 0.55),
        pillTop: Color(r: 252, g: 254, b: 255, a: 0.62),
        pillBottom: Color(r: 212, g: 225, b: 245, a: 0.42),
        pillBorder: Color(r: 255, g: 255, b: 255, a: 0.60),
        divider: Color(r: 255, g: 255, b: 255, a: 0.30),
        shimmer: [Color(r: 126, g: 170, b: 255, a: 0.65), Color(r: 255, g: 255, b: 255, a: 0.85), Color(r: 221, g: 178, b: 124, a: 0.65)],
        routeGlow: Color(r: 255, g: 255, b: 255, a: 0.45),
        lateText: Color(hex: 0x7B3F14)
    )

    static let midnight = Theme(
        id: "midnight",
        label: "Midnight",
        tagline: "Pure OLED dark",
        ink: Color(hex: 0xF1F3F8),
        scheme: .dark,
        base: [.init(color: Color(hex: 0x0A0C14), location: 0), .init(color: Color(hex: 0x060810), location: 0.5), .init(color: Color(hex: 0x02030A), location: 1)],
        baseStart: deg165.0,
        baseEnd: deg165.1,
        glows: [
            Glow(center: UnitPoint(x: 0.18, y: 0.12), color: Color(r: 40, g: 58, b: 100, a: 0.35), reach: 0.38),
            Glow(center: UnitPoint(x: 0.86, y: 0.88), color: Color(r: 80, g: 50, b: 110, a: 0.28), reach: 0.40),
        ],
        cardTop: Color(r: 38, g: 42, b: 54, a: 0.88),
        cardBottom: Color(r: 22, g: 25, b: 34, a: 0.78),
        insetTop: Color(r: 42, g: 46, b: 58, a: 0.65),
        insetBottom: Color(r: 26, g: 28, b: 36, a: 0.45),
        insetBorder: Color(r: 255, g: 255, b: 255, a: 0.10),
        pillTop: Color(r: 48, g: 52, b: 64, a: 0.70),
        pillBottom: Color(r: 32, g: 35, b: 44, a: 0.55),
        pillBorder: Color(r: 255, g: 255, b: 255, a: 0.12),
        divider: Color(r: 255, g: 255, b: 255, a: 0.08),
        shimmer: [Color(r: 120, g: 160, b: 240, a: 0.70), Color(r: 255, g: 255, b: 255, a: 0.95), Color(r: 220, g: 180, b: 130, a: 0.70)],
        routeGlow: Color(r: 255, g: 255, b: 255, a: 0.55),
        lateText: Color(hex: 0xFBBF24)
    )

    static let aurora = Theme(
        id: "aurora",
        label: "Aurora",
        tagline: "Purple & teal glow",
        ink: Color(hex: 0xF4F0FF),
        scheme: .dark,
        base: [
            .init(color: Color(hex: 0x220846), location: 0), .init(color: Color(hex: 0x3A1380), location: 0.28),
            .init(color: Color(hex: 0x0D3675), location: 0.60), .init(color: Color(hex: 0x07484E), location: 1),
        ],
        baseStart: deg165.0,
        baseEnd: deg165.1,
        glows: [
            Glow(center: UnitPoint(x: 0.18, y: 0.12), color: Color(r: 200, g: 100, b: 255, a: 0.55), reach: 0.38),
            Glow(center: UnitPoint(x: 0.88, y: 0.18), color: Color(r: 80, g: 230, b: 220, a: 0.50), reach: 0.32),
            Glow(center: UnitPoint(x: 0.12, y: 0.82), color: Color(r: 255, g: 100, b: 180, a: 0.30), reach: 0.38),
            Glow(center: UnitPoint(x: 0.82, y: 0.86), color: Color(r: 80, g: 200, b: 240, a: 0.40), reach: 0.35),
        ],
        cardTop: Color(r: 255, g: 245, b: 255, a: 0.20),
        cardBottom: Color(r: 180, g: 220, b: 245, a: 0.12),
        insetTop: Color(r: 255, g: 245, b: 255, a: 0.18),
        insetBottom: Color(r: 180, g: 220, b: 240, a: 0.10),
        insetBorder: Color(r: 220, g: 200, b: 255, a: 0.32),
        pillTop: Color(r: 255, g: 240, b: 255, a: 0.22),
        pillBottom: Color(r: 180, g: 220, b: 240, a: 0.14),
        pillBorder: Color(r: 220, g: 200, b: 255, a: 0.40),
        divider: Color(r: 220, g: 200, b: 255, a: 0.25),
        shimmer: [Color(r: 220, g: 130, b: 255, a: 0.85), Color(r: 255, g: 255, b: 255, a: 0.95), Color(r: 100, g: 230, b: 220, a: 0.85)],
        routeGlow: Color(r: 220, g: 180, b: 255, a: 0.55),
        lateText: Color(hex: 0xFBBF24)
    )

    static let sunset = Theme(
        id: "sunset",
        label: "Sunset",
        tagline: "Warm dusk gradient",
        ink: Color(hex: 0x2A1410),
        scheme: .light,
        base: [
            .init(color: Color(hex: 0xFFD29A), location: 0), .init(color: Color(hex: 0xFF9466), location: 0.35),
            .init(color: Color(hex: 0xD8517D), location: 0.70), .init(color: Color(hex: 0x6E3590), location: 1),
        ],
        baseStart: deg160.0,
        baseEnd: deg160.1,
        glows: [
            Glow(center: UnitPoint(x: 0.12, y: 0.10), color: Color(r: 255, g: 220, b: 130, a: 0.55), reach: 0.32),
            Glow(center: UnitPoint(x: 0.88, y: 0.22), color: Color(r: 255, g: 255, b: 255, a: 0.18), reach: 0.22),
            Glow(center: UnitPoint(x: 0.80, y: 0.88), color: Color(r: 180, g: 60, b: 130, a: 0.45), reach: 0.38),
            Glow(center: UnitPoint(x: 0.16, y: 0.78), color: Color(r: 255, g: 130, b: 100, a: 0.32), reach: 0.32),
        ],
        cardTop: Color(r: 255, g: 248, b: 240, a: 0.78),
        cardBottom: Color(r: 255, g: 220, b: 200, a: 0.62),
        insetTop: Color(r: 255, g: 250, b: 245, a: 0.62),
        insetBottom: Color(r: 255, g: 215, b: 195, a: 0.42),
        insetBorder: Color(r: 255, g: 232, b: 218, a: 0.55),
        pillTop: Color(r: 255, g: 248, b: 240, a: 0.65),
        pillBottom: Color(r: 255, g: 220, b: 200, a: 0.45),
        pillBorder: Color(r: 255, g: 232, b: 218, a: 0.60),
        divider: Color(r: 80, g: 30, b: 50, a: 0.22),
        shimmer: [Color(r: 255, g: 140, b: 80, a: 0.85), Color(r: 255, g: 240, b: 220, a: 0.95), Color(r: 180, g: 80, b: 160, a: 0.85)],
        routeGlow: Color(r: 255, g: 220, b: 180, a: 0.55),
        lateText: Color(hex: 0x8A3F12)
    )

    static let liquid = Theme(
        id: "liquid",
        label: "Liquid",
        tagline: "Pale glass, iOS 26 style",
        ink: Color(hex: 0x0D1828),
        scheme: .light,
        base: [
            .init(color: Color(hex: 0xC8E1F5), location: 0), .init(color: Color(hex: 0xAAC3E0), location: 0.38),
            .init(color: Color(hex: 0x8A9EC5), location: 0.70), .init(color: Color(hex: 0x6E83B0), location: 1),
        ],
        baseStart: deg160.0,
        baseEnd: deg160.1,
        glows: [
            Glow(center: UnitPoint(x: 0.14, y: 0.08), color: Color(r: 140, g: 200, b: 255, a: 0.45), reach: 0.32),
            Glow(center: UnitPoint(x: 0.86, y: 0.18), color: Color(r: 255, g: 220, b: 240, a: 0.32), reach: 0.26),
            Glow(center: UnitPoint(x: 0.78, y: 0.86), color: Color(r: 255, g: 200, b: 140, a: 0.40), reach: 0.36),
            Glow(center: UnitPoint(x: 0.16, y: 0.80), color: Color(r: 180, g: 140, b: 255, a: 0.38), reach: 0.32),
            // v4's tilt highlight, resting position.
            Glow(center: UnitPoint(x: 0.50, y: 0.15), color: Color(r: 255, g: 255, b: 255, a: 0.28), reach: 0.55),
        ],
        cardTop: Color(r: 255, g: 255, b: 255, a: 0.45),
        cardBottom: Color(r: 220, g: 235, b: 255, a: 0.22),
        insetTop: Color(r: 255, g: 255, b: 255, a: 0.38),
        insetBottom: Color(r: 220, g: 235, b: 255, a: 0.18),
        insetBorder: Color(r: 255, g: 255, b: 255, a: 0.55),
        pillTop: Color(r: 255, g: 255, b: 255, a: 0.40),
        pillBottom: Color(r: 220, g: 235, b: 255, a: 0.20),
        pillBorder: Color(r: 255, g: 255, b: 255, a: 0.60),
        divider: Color(r: 40, g: 60, b: 100, a: 0.22),
        shimmer: [Color(r: 140, g: 200, b: 255, a: 0.85), Color(r: 255, g: 255, b: 255, a: 0.95), Color(r: 255, g: 200, b: 140, a: 0.85)],
        routeGlow: Color(r: 255, g: 255, b: 255, a: 0.60),
        lateText: Color(hex: 0x7B3F14)
    )
}

/// Fixed accents that sit on top of every theme (v4's @theme and badge colors).
enum Accent {
    static let hoboken = Color(hex: 0x7EAAFF)
    static let penn = Color(hex: 0xDDB27C)
    static let am = Color(hex: 0xE9B378)
    static let pm = Color(hex: 0x6F99CE)
    static let delay = Color(hex: 0xF59E0B)
    static let track = Color(hex: 0x3B82F6)
    static let cancel = Color(hex: 0xEF4444)
    static let live = Color(r: 34, g: 197, b: 94, a: 1)
    static let onTime = Color(hex: 0x10B981)

    static func destination(_ id: String) -> Color {
        id == "penn" ? penn : hoboken
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// CSS `rgba(r, g, b, a)`.
    init(r: Double, g: Double, b: Double, a: Double) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

/// The page behind everything: the theme's base gradient, its radial glows,
/// and v4's full-screen frosted card (on a phone the card filled the screen).
struct ThemeBackdrop: View {
    let theme: Theme
    var showsCard = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(stops: theme.base, startPoint: theme.baseStart, endPoint: theme.baseEnd)
                ForEach(Array(theme.glows.enumerated()), id: \.offset) { _, glow in
                    RadialGradient(
                        colors: [glow.color, glow.color.opacity(0)],
                        center: glow.center,
                        startRadius: 0,
                        endRadius: max(1, glow.reach * Self.farthestCorner(from: glow.center, in: size))
                    )
                }
                if showsCard {
                    LinearGradient(colors: [theme.cardTop, theme.cardBottom], startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }

    static func farthestCorner(from center: UnitPoint, in size: CGSize) -> CGFloat {
        let dx = max(center.x, 1 - center.x) * size.width
        let dy = max(center.y, 1 - center.y) * size.height
        return (dx * dx + dy * dy).squareRoot()
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .glass
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
