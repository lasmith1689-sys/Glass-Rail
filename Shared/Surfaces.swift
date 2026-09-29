import SwiftUI

/// v4's `.glass-inset` panel: a light frosted gradient with a hairline border,
/// a top highlight and a soft drop shadow.
struct InsetPanel: ViewModifier {
    @Environment(\.theme) private var theme
    let radius: CGFloat
    var highlight: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                shape.fill(LinearGradient(colors: [theme.insetTop, theme.insetBottom], startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                shape.strokeBorder(highlight ?? theme.insetBorder, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // `inset 0 1px 0 rgba(255,255,255,0.4)`: a lit top edge.
                shape
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.4), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 6)
    }
}

/// v4's `.glass-pill` for chips that are not buttons (status, freshness).
struct PillSurface: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(LinearGradient(colors: [theme.pillTop, theme.pillBottom], startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(theme.pillBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 4)
    }
}

extension View {
    func insetPanel(radius: CGFloat = 24, highlight: Color? = nil) -> some View {
        modifier(InsetPanel(radius: radius, highlight: highlight))
    }

    func pillSurface() -> some View {
        modifier(PillSurface())
    }
}

/// v4's status badges: accent-tinted chip, accent dot, ink text.
struct AlertBadge: View {
    enum Tone {
        case delay, track, cancel

        var accent: Color {
            switch self {
            case .delay: return Accent.delay
            case .track: return Accent.track
            case .cancel: return Accent.cancel
            }
        }
    }

    let tone: Tone
    let text: String

    var body: some View {
        HStack(spacing: 5.5) {
            Circle().fill(tone.accent).frame(width: 6, height: 6)
            Text(text)
                .grFont(10, .heavy, style: .caption2, maxScale: 1.4, digits: true)
                .tracking(0.8)
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(tone.accent.opacity(0.20)))
        .overlay(Capsule().strokeBorder(tone.accent.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
