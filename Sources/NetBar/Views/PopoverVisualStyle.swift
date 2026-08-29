import AppKit
import SwiftUI

/// Shared presentation tokens for the menu popover.
///
/// Every page consumes the same spacing, radius, type and semantic-color scale.
/// Business identity survives only as a leading icon tint, never as a surface
/// fill, so the panel keeps one neutral material instead of a tinted card per
/// feature. Status colors carry exactly one meaning: how the network path is
/// doing right now.
enum PopoverVisualStyle {

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    /// The single horizontal inset shared by every page and by the tab bar, so
    /// content edges and navigation edges always line up.
    static let contentInset: CGFloat = Spacing.lg

    // MARK: - Radius

    enum Radius {
        static let badge: CGFloat = 6
        static let control: CGFloat = 10
        static let card: CGFloat = 10
        static let shell: CGFloat = 16
    }

    // MARK: - Typography

    /// The smallest tier is 11pt: `NSFont.smallSystemFontSize` is the macOS
    /// floor for readable interface text, and the previous 10pt tier was the
    /// main reason the panel read as low quality.
    enum Typography {
        static let title = Font.system(size: 16, weight: .semibold)
        static let section = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 12, weight: .regular)
        static let bodyStrong = Font.system(size: 12, weight: .semibold)
        static let caption = Font.system(size: 11, weight: .regular)
        static let captionStrong = Font.system(size: 11, weight: .semibold)
        static let data = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let metric = Font.system(size: 20, weight: .semibold, design: .monospaced)
    }

    // MARK: - Semantic status colors

    static let healthy = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let fault = Color(nsColor: .systemRed)

    /// Owns every actionable control. Keeping actions off the status palette
    /// lets `healthy` mean one thing only — the path is proven — instead of
    /// doubling as "this button is safe to press".
    ///
    /// Follows the system accent, except when that accent is graphite: a grey
    /// accent leaves selection with no hue to differentiate with, which is the
    /// grey-on-grey problem this design exists to remove.
    static var accent: Color {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "AppleAccentColor") != nil else {
            return Color(nsColor: .controlAccentColor)
        }
        return defaults.integer(forKey: "AppleAccentColor") == graphiteAccentValue
            ? Color(nsColor: .systemBlue)
            : Color(nsColor: .controlAccentColor)
    }

    private static let graphiteAccentValue = -1

    // MARK: - Business identity

    /// Used to tint a card's leading icon. Never used as a surface fill.
    static let ipAccent = Color(nsColor: .systemPurple)
    static let vpsAccent = Color(nsColor: .systemCyan)

    // MARK: - Text

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Surfaces

    /// Surfaces are dynamic rather than a single `Color.primary.opacity(...)`:
    /// a light-mode alpha that reads correctly turns invisible once it is
    /// composited over `.regularMaterial` in Dark Aqua.
    static let surface = Color(nsColor: .popoverDynamic(
        light: NSColor.black.withAlphaComponent(0.045),
        dark: NSColor.white.withAlphaComponent(0.075)
    ))

    static let surfaceSelected = Color(nsColor: .popoverDynamic(
        light: NSColor.black.withAlphaComponent(0.085),
        dark: NSColor.white.withAlphaComponent(0.140)
    ))

    static let hairline = Color(nsColor: .separatorColor)

    static func color(for state: PopoverFactState) -> Color {
        switch state {
        case .ok: return healthy
        case .unknown: return tertiaryText
        case .warning: return warning
        case .fault: return fault
        }
    }

    static func color(for tone: PopoverStatusTone) -> Color {
        switch tone {
        case .positive: return healthy
        case .caution: return warning
        case .negative: return fault
        case .neutral: return secondaryText
        }
    }
}

/// Four states, because "not sampled yet" is not a warning.
///
/// The previous two-state model (`healthy ? green : orange`) painted every
/// unknown fact orange, which is why a freshly opened panel looked like a wall
/// of problems.
enum PopoverFactState: Equatable {
    case ok
    case unknown
    case warning
    case fault

    /// `nil` means the fact has not been sampled yet.
    init(ready: Bool?) {
        switch ready {
        case .some(true): self = .ok
        case .some(false): self = .warning
        case .none: self = .unknown
        }
    }
}

/// Filled for a known state, hollow for an unsampled one.
struct PopoverStatusDot: View {
    let state: PopoverFactState
    var diameter: CGFloat = 7

    var body: some View {
        Group {
            if state == .unknown {
                Circle().strokeBorder(PopoverVisualStyle.tertiaryText, lineWidth: 1)
            } else {
                Circle().fill(PopoverVisualStyle.color(for: state))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct PopoverSurfaceModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(PopoverVisualStyle.surface)
            )
    }
}

extension View {
    /// The single neutral surface primitive. Cards, control tracks and empty
    /// states all sit on it so the panel never stacks grey on grey.
    func popoverSurface(radius: CGFloat = PopoverVisualStyle.Radius.card) -> some View {
        modifier(PopoverSurfaceModifier(radius: radius))
    }
}

private extension NSColor {
    static func popoverDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
