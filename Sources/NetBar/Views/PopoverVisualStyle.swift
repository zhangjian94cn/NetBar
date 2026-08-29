import AppKit
import SwiftUI

/// Shared presentation tokens for the menu popover.
///
/// Every page consumes the same spacing, radius, type and semantic-color scale.
/// The panel carries exactly two color roles: status (green / orange / red) and
/// accent (selection, actions and meters). Everything else is neutral, so a
/// colored pixel always means something.
enum PopoverVisualStyle {

    // MARK: - Panel geometry

    /// The panel's only geometry source. `StatusBarController` sizes the window
    /// from it and `MenuPopoverView` frames the root view from it, so a resize
    /// is a single edit instead of two constants drifting apart.
    enum Metrics {
        static let panelWidth: CGFloat = 340
        static let directFullHeight: CGFloat = 460
        static let appStoreLiteHeight: CGFloat = 390
        static let panelMinHeight: CGFloat = 340
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    /// The single horizontal inset shared by every page and by the tab bar, so
    /// content edges and navigation edges always line up.
    static let contentInset: CGFloat = Spacing.md

    /// Gap between the stacked blocks of a page.
    static let blockSpacing: CGFloat = Spacing.sm

    /// Inner padding of a card or a grouped list.
    static let cardPadding: CGFloat = 10

    // MARK: - Radius

    enum Radius {
        static let badge: CGFloat = 5
        static let control: CGFloat = 8
        static let card: CGFloat = 8
        static let shell: CGFloat = 12
    }

    // MARK: - Typography

    /// A dense five-tier scale for a compact utility panel: 10 / 11 / 12 / 13 / 15.
    ///
    /// An earlier revision raised the floor to 11pt because that is
    /// `NSFont.smallSystemFontSize`. In this panel that traded away the density
    /// the tool is for, and 10pt is ordinary for short secondary labels in a
    /// macOS menu bar utility. The hierarchy defect that revision fixed was the
    /// *absence of distinct tiers*, not the floor itself, so the tiers stay
    /// distinct here while every one of them drops a step.
    enum Typography {
        static let title = Font.system(size: 13, weight: .semibold)
        static let section = Font.system(size: 12, weight: .semibold)
        static let body = Font.system(size: 11, weight: .regular)
        static let bodyStrong = Font.system(size: 11, weight: .semibold)
        static let caption = Font.system(size: 10, weight: .regular)
        static let captionStrong = Font.system(size: 10, weight: .semibold)
        static let data = Font.system(size: 10, weight: .medium, design: .monospaced)
        static let metric = Font.system(size: 15, weight: .semibold, design: .monospaced)
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

    // MARK: - Meters

    /// Fill for proportion bars and sparklines. Data density, not decoration:
    /// it is the accent at low opacity so a meter never competes with the
    /// status dots sitting next to it.
    static let meterFill = accent.opacity(0.55)
    static let meterTrack = Color(nsColor: .popoverDynamic(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.12)
    ))

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
