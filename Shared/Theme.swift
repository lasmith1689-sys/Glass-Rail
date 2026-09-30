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

    /// A soft light behind the glass.
    struct Orb: Equatable {
        var center: UnitPoint
        var color: Color
        /// Diameter as a fraction of the screen width.
        var size: CGFloat
        /// How far it drifts, in points, over one slow cycle.
        var drift: CGSize
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
    /// See-through themes drop v4's frosted page veil: the cards become real
    /// Liquid Glass over a living backdrop you can see through them.
    var seeThrough = false
    /// Tint mixed into the glass of a see-through theme's cards.
    var glassTint: Color = .clear
    /// A faint sheen painted on the glass, top to bottom, for legibility.
    var glassSheen: [Color] = [.clear, .clear]
    /// What a card falls back to when Reduce Transparency is on.
    var solidPanel: Color = .clear
    /// Soft lights that drift slowly behind the glass (app only).
    var orbs: [Orb] = []
    /// How the faint rails behind the glass are drawn.
    var rails: RailStyle = .curves
    /// Opaque themes normally lay v4's frosted card over the whole page; a theme
    /// with solid cards of its own (Station) goes without it.
    var pageVeil = true
    /// A bundled font family for all of this theme's text (nil: the system font).
    var fontFamily: FontFamily?

    enum RailStyle: Equatable {
        /// Two tracks sweeping across the screen.
        case curves
        /// One straight track running away to a vanishing point, headlight at the end.
        case perspective
    }

    enum FontFamily: String, Equatable {
        case oswald = "Oswald"

        /// The PostScript name of the bundled face closest to a weight.
        func faceName(_ weight: Font.Weight) -> String {
            switch weight {
            case .ultraLight, .thin, .light: return "Oswald-Light"
            case .regular: return "Oswald-Regular"
            case .medium: return "Oswald-Medium"
            case .semibold: return "Oswald-SemiBold"
            default: return "Oswald-Bold"
            }
        }

        /// Oswald is tall and condensed: at the same point size it sets taller lines than SF, so
        /// it runs a touch smaller to keep the board's layout where it is.
        var sizeScale: CGFloat { 0.9 }

        static let allFaces = ["Oswald-Light", "Oswald-Regular", "Oswald-Medium", "Oswald-SemiBold", "Oswald-Bold"]
    }

    static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }

    static let all: [Theme] = [.glass, .midnight, .aurora, .sunset, .liquid, .platform, .ember, .navy, .station]

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
        tagline: "Default · see-through glass",
        ink: Color(hex: 0xF4F7FC),
        scheme: .dark,
        base: [.init(color: Color(hex: 0x1C2C5A), location: 0), .init(color: Color(hex: 0x111B3C), location: 0.45), .init(color: Color(hex: 0x0A1027), location: 1)],
        baseStart: deg160.0,
        baseEnd: deg160.1,
        glows: [
            Glow(center: UnitPoint(x: 0.10, y: 0.05), color: Color(r: 70, g: 120, b: 255, a: 0.50), reach: 0.42),
            Glow(center: UnitPoint(x: 0.90, y: 0.22), color: Color(r: 90, g: 200, b: 255, a: 0.22), reach: 0.30),
            Glow(center: UnitPoint(x: 0.85, y: 0.90), color: Color(r: 230, g: 170, b: 90, a: 0.42), reach: 0.40),
            Glow(center: UnitPoint(x: 0.10, y: 0.76), color: Color(r: 140, g: 90, b: 230, a: 0.38), reach: 0.38),
        ],
        cardTop: Color(r: 255, g: 255, b: 255, a: 0.24),
        cardBottom: Color(r: 255, g: 255, b: 255, a: 0.08),
        insetTop: Color(r: 255, g: 255, b: 255, a: 0.11),
        insetBottom: Color(r: 255, g: 255, b: 255, a: 0.04),
        insetBorder: Color(r: 255, g: 255, b: 255, a: 0.18),
        pillTop: Color(r: 255, g: 255, b: 255, a: 0.14),
        pillBottom: Color(r: 255, g: 255, b: 255, a: 0.05),
        pillBorder: Color(r: 255, g: 255, b: 255, a: 0.22),
        divider: Color(r: 255, g: 255, b: 255, a: 0.12),
        shimmer: [Color(r: 126, g: 170, b: 255, a: 0.75), Color(r: 255, g: 255, b: 255, a: 0.95), Color(r: 221, g: 178, b: 124, a: 0.75)],
        routeGlow: Color(r: 255, g: 255, b: 255, a: 0.55),
        lateText: Color(hex: 0xFBBF24),
        seeThrough: true,
        glassTint: Color(r: 90, g: 120, b: 200, a: 0.14),
        glassSheen: [Color(r: 255, g: 255, b: 255, a: 0.09), Color(r: 255, g: 255, b: 255, a: 0.02)],
        solidPanel: Color(hex: 0x1A2548),
        orbs: [
            Orb(center: UnitPoint(x: 0.12, y: 0.24), color: Color(r: 60, g: 110, b: 255, a: 0.60), size: 1.00, drift: CGSize(width: 48, height: 40)),
            Orb(center: UnitPoint(x: 0.92, y: 0.10), color: Color(r: 60, g: 200, b: 225, a: 0.34), size: 0.60, drift: CGSize(width: -32, height: 28)),
            Orb(center: UnitPoint(x: 0.90, y: 0.62), color: Color(r: 240, g: 168, b: 80, a: 0.50), size: 0.85, drift: CGSize(width: -44, height: -58)),
            Orb(center: UnitPoint(x: 0.22, y: 0.88), color: Color(r: 150, g: 95, b: 240, a: 0.46), size: 0.80, drift: CGSize(width: 38, height: -32)),
        ]
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
        lateText: Color(hex: 0x7B3F14),
        seeThrough: true,
        glassTint: Color(r: 255, g: 255, b: 255, a: 0.16),
        glassSheen: [Color(r: 255, g: 255, b: 255, a: 0.30), Color(r: 255, g: 255, b: 255, a: 0.08)],
        solidPanel: Color(hex: 0xDDE8F5),
        orbs: [
            Orb(center: UnitPoint(x: 0.14, y: 0.20), color: Color(r: 120, g: 190, b: 255, a: 0.60), size: 0.95, drift: CGSize(width: 44, height: 36)),
            Orb(center: UnitPoint(x: 0.90, y: 0.58), color: Color(r: 255, g: 190, b: 140, a: 0.55), size: 0.85, drift: CGSize(width: -40, height: -52)),
            Orb(center: UnitPoint(x: 0.24, y: 0.88), color: Color(r: 185, g: 150, b: 255, a: 0.50), size: 0.80, drift: CGSize(width: 36, height: -30)),
        ]
    )

    // MARK: The four looks from the September design samples: same board, new light.

    static let platform = Theme(
        id: "platform",
        label: "Platform",
        tagline: "Night platform, warm lights",
        ink: Color(hex: 0xF5F7FB),
        scheme: .dark,
        base: [
            .init(color: Color(hex: 0x0B1636), location: 0), .init(color: Color(hex: 0x16295F), location: 0.42),
            .init(color: Color(hex: 0x2A2D57), location: 0.66), .init(color: Color(hex: 0x2A1C22), location: 1),
        ],
        baseStart: .top,
        baseEnd: .bottom,
        glows: [
            Glow(center: UnitPoint(x: 0.04, y: 0.80), color: Color(r: 255, g: 176, b: 96, a: 0.62), reach: 0.40),
            Glow(center: UnitPoint(x: 0.94, y: 0.74), color: Color(r: 255, g: 206, b: 140, a: 0.52), reach: 0.36),
            Glow(center: UnitPoint(x: 0.50, y: 0.30), color: Color(r: 170, g: 205, b: 255, a: 0.40), reach: 0.24),
            Glow(center: UnitPoint(x: 0.16, y: 0.12), color: Color(r: 120, g: 150, b: 255, a: 0.28), reach: 0.22),
        ],
        cardTop: Color(r: 255, g: 255, b: 255, a: 0.24),
        cardBottom: Color(r: 255, g: 255, b: 255, a: 0.08),
        insetTop: Color(r: 255, g: 255, b: 255, a: 0.11),
        insetBottom: Color(r: 255, g: 255, b: 255, a: 0.04),
        insetBorder: Color(r: 255, g: 255, b: 255, a: 0.18),
        pillTop: Color(r: 255, g: 255, b: 255, a: 0.14),
        pillBottom: Color(r: 255, g: 255, b: 255, a: 0.05),
        pillBorder: Color(r: 255, g: 255, b: 255, a: 0.22),
        divider: Color(r: 255, g: 255, b: 255, a: 0.12),
        shimmer: [Color(r: 143, g: 180, b: 255, a: 0.80), Color(r: 255, g: 255, b: 255, a: 0.95), Color(r: 255, g: 196, b: 120, a: 0.80)],
        routeGlow: Color(r: 255, g: 255, b: 255, a: 0.55),
        lateText: Color(hex: 0xFBBF24),
        seeThrough: true,
        glassTint: Color(r: 90, g: 120, b: 200, a: 0.12),
        glassSheen: [Color(r: 255, g: 255, b: 255, a: 0.09), Color(r: 255, g: 255, b: 255, a: 0.02)],
        solidPanel: Color(hex: 0x1A2548),
        orbs: [
            Orb(center: UnitPoint(x: 0.10, y: 0.78), color: Color(r: 255, g: 176, b: 96, a: 0.46), size: 0.80, drift: CGSize(width: 30, height: -24)),
            Orb(center: UnitPoint(x: 0.90, y: 0.70), color: Color(r: 255, g: 206, b: 140, a: 0.40), size: 0.70, drift: CGSize(width: -28, height: 22)),
            Orb(center: UnitPoint(x: 0.50, y: 0.30), color: Color(r: 170, g: 205, b: 255, a: 0.30), size: 0.45, drift: CGSize(width: 0, height: 18)),
        ],
        rails: .perspective
    )

    static let ember = Theme(
        id: "ember",
        label: "Ember",
        tagline: "Amber glow on graphite",
        ink: Color(hex: 0xF5F2EC),
        scheme: .dark,
        base: [.init(color: Color(hex: 0x16151C), location: 0), .init(color: Color(hex: 0x0F1018), location: 0.5), .init(color: Color(hex: 0x0A0C14), location: 1)],
        baseStart: deg165.0,
        baseEnd: deg165.1,
        glows: [
            Glow(center: UnitPoint(x: 0.50, y: 0.30), color: Color(r: 255, g: 170, b: 60, a: 0.40), reach: 0.46),
            Glow(center: UnitPoint(x: 0.50, y: 0.34), color: Color(r: 120, g: 84, b: 40, a: 0.45), reach: 0.62),
            Glow(center: UnitPoint(x: 0.08, y: 0.88), color: Color(r: 90, g: 130, b: 255, a: 0.25), reach: 0.36),
        ],
        cardTop: Color(r: 255, g: 255, b: 255, a: 0.22),
        cardBottom: Color(r: 255, g: 255, b: 255, a: 0.07),
        insetTop: Color(r: 255, g: 248, b: 240, a: 0.10),
        insetBottom: Color(r: 255, g: 248, b: 240, a: 0.04),
        insetBorder: Color(r: 255, g: 236, b: 210, a: 0.18),
        pillTop: Color(r: 255, g: 248, b: 240, a: 0.13),
        pillBottom: Color(r: 255, g: 248, b: 240, a: 0.05),
        pillBorder: Color(r: 255, g: 236, b: 210, a: 0.22),
        divider: Color(r: 255, g: 236, b: 210, a: 0.12),
        shimmer: [Color(r: 255, g: 210, b: 122, a: 0.85), Color(r: 255, g: 255, b: 255, a: 0.95), Color(r: 255, g: 159, b: 46, a: 0.85)],
        routeGlow: Color(r: 255, g: 200, b: 120, a: 0.60),
        lateText: Color(hex: 0xFBBF24),
        seeThrough: true,
        glassTint: Color(r: 255, g: 190, b: 110, a: 0.08),
        glassSheen: [Color(r: 255, g: 255, b: 255, a: 0.08), Color(r: 255, g: 255, b: 255, a: 0.02)],
        solidPanel: Color(hex: 0x221D1A),
        orbs: [
            Orb(center: UnitPoint(x: 0.50, y: 0.28), color: Color(r: 255, g: 170, b: 60, a: 0.34), size: 0.95, drift: CGSize(width: 22, height: 26)),
            Orb(center: UnitPoint(x: 0.10, y: 0.86), color: Color(r: 90, g: 130, b: 255, a: 0.30), size: 0.80, drift: CGSize(width: 34, height: -28)),
        ]
    )

    static let navy = Theme(
        id: "navy",
        label: "Navy",
        tagline: "Deep blue, gold light",
        ink: Color(hex: 0xF5F7FB),
        scheme: .dark,
        base: [.init(color: Color(hex: 0x09112B), location: 0), .init(color: Color(hex: 0x060C20), location: 0.5), .init(color: Color(hex: 0x03050E), location: 1)],
        baseStart: deg165.0,
        baseEnd: deg165.1,
        glows: [
            Glow(center: UnitPoint(x: 0.90, y: 0.10), color: Color(r: 110, g: 150, b: 255, a: 0.26), reach: 0.36),
            Glow(center: UnitPoint(x: 0.08, y: 0.90), color: Color(r: 232, g: 182, b: 110, a: 0.42), reach: 0.52),
            Glow(center: UnitPoint(x: 0.95, y: 0.62), color: Color(r: 232, g: 182, b: 110, a: 0.16), reach: 0.30),
        ],
        cardTop: Color(r: 255, g: 255, b: 255, a: 0.22),
        cardBottom: Color(r: 255, g: 255, b: 255, a: 0.07),
        insetTop: Color(r: 255, g: 255, b: 255, a: 0.10),
        insetBottom: Color(r: 255, g: 255, b: 255, a: 0.04),
        insetBorder: Color(r: 255, g: 255, b: 255, a: 0.17),
        pillTop: Color(r: 255, g: 255, b: 255, a: 0.13),
        pillBottom: Color(r: 255, g: 255, b: 255, a: 0.05),
        pillBorder: Color(r: 255, g: 255, b: 255, a: 0.21),
        divider: Color(r: 255, g: 255, b: 255, a: 0.12),
        shimmer: [Color(r: 158, g: 192, b: 255, a: 0.85), Color(r: 255, g: 255, b: 255, a: 0.95), Color(r: 221, g: 178, b: 124, a: 0.85)],
        routeGlow: Color(r: 200, g: 220, b: 255, a: 0.55),
        lateText: Color(hex: 0xFBBF24),
        seeThrough: true,
        glassTint: Color(r: 40, g: 70, b: 170, a: 0.20),
        glassSheen: [Color(r: 255, g: 255, b: 255, a: 0.08), Color(r: 255, g: 255, b: 255, a: 0.02)],
        solidPanel: Color(hex: 0x141D3A),
        orbs: [
            Orb(center: UnitPoint(x: 0.86, y: 0.14), color: Color(r: 110, g: 150, b: 255, a: 0.26), size: 0.70, drift: CGSize(width: -30, height: 26)),
            Orb(center: UnitPoint(x: 0.12, y: 0.86), color: Color(r: 232, g: 182, b: 110, a: 0.40), size: 0.95, drift: CGSize(width: 32, height: -30)),
        ]
    )

    static let station = Theme(
        id: "station",
        label: "Station",
        tagline: "Departure board type",
        ink: Color(hex: 0xF3EFE3),
        scheme: .dark,
        base: [.init(color: Color(hex: 0x1C1A16), location: 0), .init(color: Color(hex: 0x121214), location: 0.45), .init(color: Color(hex: 0x0C0D10), location: 1)],
        baseStart: .top,
        baseEnd: .bottom,
        glows: [
            Glow(center: UnitPoint(x: 0.50, y: 0.0), color: Color(r: 255, g: 200, b: 120, a: 0.22), reach: 0.55),
        ],
        cardTop: Color(hex: 0x1B1C20),
        cardBottom: Color(hex: 0x141518),
        insetTop: Color(hex: 0x1D1E22, alpha: 0.97),
        insetBottom: Color(hex: 0x141518, alpha: 0.97),
        insetBorder: Color(r: 243, g: 239, b: 227, a: 0.12),
        pillTop: Color(hex: 0x26272C),
        pillBottom: Color(hex: 0x1C1D21),
        pillBorder: Color(r: 243, g: 239, b: 227, a: 0.14),
        divider: Color(r: 243, g: 239, b: 227, a: 0.10),
        shimmer: [Color(r: 245, g: 165, b: 36, a: 0.85), Color(r: 247, g: 242, b: 228, a: 0.95), Color(r: 245, g: 165, b: 36, a: 0.85)],
        routeGlow: Color(r: 245, g: 165, b: 36, a: 0.45),
        lateText: Color(hex: 0xF5A524),
        pageVeil: false,
        fontFamily: .oswald
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

/// The page behind everything: the theme's base gradient and its radial glows.
/// Opaque themes add v4's full-screen frosted card (on a phone the card filled
/// the screen). See-through themes skip it, and in the app they add slow
/// drifting lights and faint rails, so the glass has something to show through.
struct ThemeBackdrop: View {
    let theme: Theme
    var showsCard = true
    /// Draw the drifting lights and rails (the app's board, not widgets).
    var lively = false

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
                if lively && theme.seeThrough {
                    GlassScenery(theme: theme, size: size)
                }
                if showsCard && !theme.seeThrough && theme.pageVeil {
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

/// What the glass shows through: two faint rail lines curving across the
/// screen and a few soft lights that drift over about twenty seconds. The
/// drift runs only while the app is on screen and motion is allowed.
struct GlassScenery: View {
    let theme: Theme
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var drifted = false

    private var animating: Bool { !reduceMotion && scenePhase == .active }

    var body: some View {
        ZStack {
            RailLines(color: theme.ink, style: theme.rails)
            ForEach(Array(theme.orbs.enumerated()), id: \.offset) { _, orb in
                let diameter = orb.size * size.width
                // A radial fade instead of a blur: soft edges, and moving it is
                // only a transform.
                Circle()
                    .fill(RadialGradient(colors: [orb.color, orb.color.opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2))
                    .frame(width: diameter, height: diameter)
                    .position(x: orb.center.x * size.width, y: orb.center.y * size.height)
                    .offset(drifted ? orb.drift : .zero)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { setDrift(animating) }
        .onChange(of: animating) { _, running in setDrift(running) }
    }

    private func setDrift(_ running: Bool) {
        // Same pattern as the route shimmer: replacing the repeating animation
        // with none stops it; a new one starts from rest on the next turn.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { drifted = false }
        guard running else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                drifted = true
            }
        }
    }
}

/// Two tracks drawn like rails: a near one sweeping up from the bottom left and
/// a thinner far one, each a pair of rails with ties. Barely there on their
/// own; under the glass they bend at the card edges, which is what makes the
/// cards read as glass.
struct RailLines: View {
    let color: Color
    var style: Theme.RailStyle = .curves

    var body: some View {
        Canvas { context, size in
            if style == .perspective {
                Self.drawPerspective(size: size, color: color, in: &context)
                return
            }
            let w = size.width
            let h = size.height
            let near = Path { path in
                path.move(to: CGPoint(x: -0.25 * w, y: 1.02 * h))
                path.addCurve(
                    to: CGPoint(x: 1.25 * w, y: 0.16 * h),
                    control1: CGPoint(x: 0.50 * w, y: 0.96 * h),
                    control2: CGPoint(x: 0.42 * w, y: 0.34 * h)
                )
            }
            let far = Path { path in
                path.move(to: CGPoint(x: -0.2 * w, y: 0.40 * h))
                path.addCurve(
                    to: CGPoint(x: 1.2 * w, y: 0.02 * h),
                    control1: CGPoint(x: 0.35 * w, y: 0.36 * h),
                    control2: CGPoint(x: 0.60 * w, y: 0.08 * h)
                )
            }
            Self.draw(near, gauge: 26, tie: 36, rail: 1.6, opacity: 1, color: color, in: &context)
            Self.draw(far, gauge: 13, tie: 19, rail: 1, opacity: 0.6, color: color, in: &context)
        }
        .allowsHitTesting(false)
    }

    /// One straight track running away from the viewer: two rails converging on a
    /// vanishing point about a third of the way down, ties that shrink and close
    /// up toward it, and a small warm headlight where the rails meet.
    private static func drawPerspective(size: CGSize, color: Color, in context: inout GraphicsContext) {
        let w = size.width
        let h = size.height
        // The horizon sits low, in the gap between the train card and "Later this way", so the
        // headlight shows between the cards and the track fans out under the bottom of the board.
        let vanish = CGPoint(x: 0.5 * w, y: 0.80 * h)
        let leftFoot = CGPoint(x: -0.15 * w, y: 1.04 * h)
        let rightFoot = CGPoint(x: 1.15 * w, y: 1.04 * h)
        func along(_ foot: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: foot.x + (vanish.x - foot.x) * t, y: foot.y + (vanish.y - foot.y) * t)
        }
        // Ties: evenly spaced on the ground, so they bunch up with distance.
        for k in 0..<14 {
            let t = 1 - 1 / (1 + CGFloat(k) * 0.42)
            let a = along(leftFoot, t)
            let b = along(rightFoot, t)
            let overhang = (b.x - a.x) * 0.12
            let thickness = max(1, 9 * (1 - t))
            let tie = Path(CGRect(x: a.x - overhang, y: a.y - thickness / 2, width: b.x - a.x + overhang * 2, height: thickness))
            context.fill(tie, with: .color(color.opacity(0.08)))
        }
        var rails = Path()
        rails.move(to: leftFoot)
        rails.addLine(to: vanish)
        rails.move(to: rightFoot)
        rails.addLine(to: vanish)
        context.stroke(rails, with: .color(color.opacity(0.20)), lineWidth: 2)
        let glow = Path(ellipseIn: CGRect(x: vanish.x - 22, y: vanish.y - 22, width: 44, height: 44))
        context.fill(glow, with: .color(Color(r: 255, g: 236, b: 200, a: 0.22)))
        let lamp = Path(ellipseIn: CGRect(x: vanish.x - 3.5, y: vanish.y - 3.5, width: 7, height: 7))
        context.fill(lamp, with: .color(Color(r: 255, g: 244, b: 220, a: 0.9)))
    }

    private static func draw(_ center: Path, gauge: CGFloat, tie: CGFloat, rail: CGFloat, opacity: Double, color: Color, in context: inout GraphicsContext) {
        // Ties: a wide dashed stroke along the center line.
        context.stroke(center, with: .color(color.opacity(0.05 * opacity)), style: StrokeStyle(lineWidth: tie, dash: [tie * 0.09, tie * 0.42]))
        // Rails: the outline of a gauge-wide stroke is two parallel lines.
        let bed = center.strokedPath(StrokeStyle(lineWidth: gauge, lineCap: .butt))
        context.stroke(bed, with: .color(color.opacity(0.11 * opacity)), lineWidth: rail)
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
