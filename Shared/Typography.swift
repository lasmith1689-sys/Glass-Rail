import os
import SwiftUI
import UIKit

/// v4's type scale (rem sizes at 16 px) as points that still follow Dynamic
/// Type: each size scales with the reader's text size, capped so the hero
/// time never overflows the card.
struct ScaledFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.theme) private var theme
    let size: CGFloat
    let weight: Font.Weight
    let style: Font.TextStyle
    let maxScale: CGFloat
    let digits: Bool

    func body(content: Content) -> some View {
        let traits = UITraitCollection(preferredContentSizeCategory: Self.category(dynamicTypeSize))
        let scaled = UIFontMetrics(forTextStyle: Self.uiStyle(style)).scaledValue(for: size, compatibleWith: traits)
        let points = min(scaled, size * maxScale)
        // A theme with its own typeface (Station's Oswald) uses the bundled face for
        // the weight; the size is already scaled for Dynamic Type above.
        let font = theme.fontFamily.map { Font.custom($0.faceName(weight), fixedSize: points) }
            ?? Font.system(size: points, weight: weight)
        return content.font(digits ? font.monospacedDigit() : font)
    }

    static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }

    static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
}

extension View {
    /// A v4 size in points, scaled with Dynamic Type.
    func grFont(_ size: CGFloat, _ weight: Font.Weight = .regular, style: Font.TextStyle = .body, maxScale: CGFloat = 1.6, digits: Bool = false) -> some View {
        modifier(ScaledFont(size: size, weight: weight, style: style, maxScale: maxScale, digits: digits))
    }

    /// v4's `.kicker`: small, bold, tracked-out uppercase label at 68% ink.
    func kicker(_ size: CGFloat = 10.5) -> some View {
        modifier(KickerStyle(size: size))
    }
}

struct KickerStyle: ViewModifier {
    @Environment(\.theme) private var theme
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .grFont(size, .bold, style: .caption2, maxScale: 1.4)
            .tracking(size * 0.18)
            .textCase(.uppercase)
            .foregroundStyle(theme.ink.opacity(0.68))
            .lineLimit(1)
    }
}

/// Checks once at launch that every bundled theme face registered. A wrong file or
/// PostScript name fails silently (the text falls back to the system font), so the
/// result is logged for the smoke test to read.
enum ThemeFonts {
    static func check() {
        let faces = Theme.FontFamily.allFaces
        let missing = faces.filter { UIFont(name: $0, size: 12) == nil }
        let log = Logger(subsystem: "com.lasmith1689.GlassRail", category: "Fonts")
        if missing.isEmpty {
            log.notice("Theme fonts: all \(faces.count, privacy: .public) faces loaded")
        } else {
            log.error("Theme fonts missing: \(missing.joined(separator: ", "), privacy: .public)")
        }
    }
}
