import GlassRailKit
import SwiftUI

/// The route line with v4's slow shimmer and the journey dot.
struct RouteLineRow: View {
    let from: String
    let to: String
    let progress: Double
    let showsDot: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(from)
            RouteLine(progress: progress, showsDot: showsDot)
            Text(to)
        }
        .grFont(10.5, .semibold, style: .caption2, maxScale: 1.3)
        .tracking(1.7)
        .textCase(.uppercase)
        .foregroundStyle(theme.ink.opacity(0.85))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(from) to \(to)")
        .accessibilityValue(showsDot ? "\(Int((progress * 100).rounded())) percent of the way" : "")
    }
}

struct RouteLine: View {
    let progress: Double
    let showsDot: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.clear)
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        // background-size: 200%, background-position 0% to 100%.
                        LinearGradient(colors: theme.shimmer, startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 2)
                            .offset(x: shimmer ? -width : 0)
                    }
                    .clipShape(Capsule())
                    .shadow(color: theme.routeGlow, radius: 9)
                if showsDot {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .shadow(color: .white.opacity(0.9), radius: 5)
                        .offset(x: min(max(0, progress * width - 4), max(0, width - 8)))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: progress)
                }
            }
            .frame(width: width, height: proxy.size.height)
        }
        .frame(height: 8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
    }
}

/// v4's pulsing green dot for LIVE.
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Accent.live.opacity(0.55))
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 3 : 1)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(Accent.live)
                .frame(width: 8, height: 8)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// LIVE / STALE / SAMPLE.
struct FeedBadge: View {
    let mode: FeedMode

    var body: some View {
        HStack(spacing: 8) {
            if mode == .live {
                LiveDot()
            } else {
                Circle().fill(Accent.delay).frame(width: 6, height: 6)
            }
            Text(label)
                .grFont(10.5, .bold, style: .caption2, maxScale: 1.3)
                .tracking(0.5)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .pillSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var label: String {
        switch mode {
        case .live: return "Live"
        case .stale: return "Stale"
        case .sample: return "Sample"
        }
    }

    private var accessibility: String {
        switch mode {
        case .live: return "Live data"
        case .stale: return "Stale data"
        case .sample: return "Sample data, not live"
        }
    }
}

/// A round Liquid Glass icon button.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 40
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.85))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}

/// v4's "On time" chip.
struct OnTimeChip: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Accent.onTime).frame(width: 6, height: 6)
            Text("On time")
                .grFont(10.5, .bold, style: .caption2, maxScale: 1.3)
                .tracking(0.5)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .pillSurface()
    }
}

/// "Train 1074 has departed", fading out before it clears.
struct DepartedNote: View {
    let label: String
    let fading: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Train \(label) has departed")
            .grFont(11.5, .bold, style: .footnote, maxScale: 1.4, digits: true)
            .padding(.horizontal, 10.5)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(theme.ink.opacity(0.12)))
            .overlay(Capsule().strokeBorder(theme.ink.opacity(0.28), lineWidth: 1))
            .opacity(fading ? 0 : 1)
            .animation(.easeOut(duration: 0.6), value: fading)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

extension Array where Element == String {
    /// "Secaucus, Newark Broad"
    var listed: String { joined(separator: ", ") }
}
