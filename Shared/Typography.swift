import SwiftUI
import UIKit

/// v4's type scale (rem sizes at 16 px) as points that still follow Dynamic
/// Type: each size scales with the reader's text size, capped so the hero
/// time never overflows the card.
struct ScaledFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let size: CGFloat
    let weight: Font.Weight
    let style: Font.TextStyle
    let maxScale: CGFloat
    let digits: Bool

    func body(content: Content) -> some View {
        let traits = UITraitCollection(preferredContentSizeCategory: Self.category(dynamicTypeSize))
        let scaled = UIFontMetrics(forTextStyle: Self.uiStyle(style)).scaledValue(for: size, compatibleWith: traits)
        let font = Font.system(size: min(scaled, size * maxScale), weight: weight)
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
