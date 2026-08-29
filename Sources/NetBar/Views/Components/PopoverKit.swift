import AppKit
import SwiftUI

// MARK: - Facts

/// Vertical "label over value" cell, used by the outlet evidence grid and the
/// monitoring fact grid.
///
/// A `detail` that carries no information (empty or an em dash placeholder) is
/// dropped rather than rendered, so an unsampled panel does not fill up with
/// dashes.
struct PopoverFactTile: View {
    let title: String
    var icon: String?
    let value: String
    var detail: String?
    var state: PopoverFactState?
    var monospacedValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.xs / 2) {
            label
            HStack(spacing: PopoverVisualStyle.Spacing.xs) {
                if let state {
                    PopoverStatusDot(state: state, diameter: 6)
                }
                Text(value)
                    .font(monospacedValue
                          ? PopoverVisualStyle.Typography.data
                          : PopoverVisualStyle.Typography.bodyStrong)
                    .foregroundColor(valueColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let detail = Self.meaningfulDetail(detail) {
                Text(detail)
                    .font(PopoverVisualStyle.Typography.data)
                    .foregroundColor(PopoverVisualStyle.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var label: some View {
        if let icon {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.caption)
                .foregroundColor(PopoverVisualStyle.secondaryText)
        } else {
            Text(title)
                .font(PopoverVisualStyle.Typography.caption)
                .foregroundColor(PopoverVisualStyle.secondaryText)
        }
    }

    private var valueColor: Color {
        state == .unknown ? PopoverVisualStyle.secondaryText : PopoverVisualStyle.primaryText
    }

    /// Placeholder details carry no information and only add visual noise.
    static func meaningfulDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "—", trimmed != "-" else { return nil }
        return trimmed
    }
}

/// Horizontal "label … value" row, used by configuration and diagnostic lists.
///
/// State renders as a leading dot and the value text stays primary: colored
/// text at 11pt is harder to read than a dot, and it is what made the previous
/// diagnostics list look like a warning list.
struct PopoverFactRow: View {
    let title: String
    let value: String
    var state: PopoverFactState?
    /// Metadata lists (IP location, ASN, org) use the compact rhythm so a
    /// three-line block does not become as tall as a control list.
    var compact = false

    var body: some View {
        HStack(spacing: PopoverVisualStyle.Spacing.sm) {
            Text(title)
                .font(compact
                      ? PopoverVisualStyle.Typography.caption
                      : PopoverVisualStyle.Typography.body)
                .foregroundColor(PopoverVisualStyle.secondaryText)
            Spacer(minLength: PopoverVisualStyle.Spacing.sm)
            if let state {
                PopoverStatusDot(state: state, diameter: 6)
            }
            Text(value)
                .font(compact
                      ? PopoverVisualStyle.Typography.captionStrong
                      : PopoverVisualStyle.Typography.bodyStrong)
                .foregroundColor(state == .unknown
                                 ? PopoverVisualStyle.secondaryText
                                 : PopoverVisualStyle.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: compact ? 18 : 26)
    }
}

// MARK: - Card

/// Neutral surface with an accent-tinted leading icon.
///
/// The accent identifies the feature (indigo for public IP, cyan for VPS) but
/// never fills the surface, which is what turned the panel into a box of
/// crayons.
struct PopoverCard<Trailing: View, Content: View>: View {
    let icon: String
    let title: String
    var accent: Color = PopoverVisualStyle.secondaryText
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.xs + 2) {
            HStack(spacing: PopoverVisualStyle.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(accent)
                Text(title)
                    .font(PopoverVisualStyle.Typography.section)
                    .foregroundColor(PopoverVisualStyle.primaryText)
                Spacer(minLength: PopoverVisualStyle.Spacing.sm)
                trailing()
            }
            content()
        }
        .padding(PopoverVisualStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popoverSurface()
    }
}

extension PopoverCard where Trailing == EmptyView {
    init(
        icon: String,
        title: String,
        accent: Color = PopoverVisualStyle.secondaryText,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(icon: icon, title: title, accent: accent, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Disclosure

/// One expandable row. Callers stack several inside a single
/// `.popoverSurface()` and separate them with `Divider()`.
struct PopoverDisclosure<Content: View>: View {
    let icon: String
    let title: String
    var value: String?
    @Binding var isExpanded: Bool
    var onExpand: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isExpanded.toggle()
                if isExpanded { onExpand?() }
            } label: {
                HStack(spacing: PopoverVisualStyle.Spacing.sm) {
                    Image(systemName: icon)
                        .foregroundColor(PopoverVisualStyle.secondaryText)
                        .frame(width: 16)
                    Text(title)
                        .fontWeight(.medium)
                        .foregroundColor(PopoverVisualStyle.primaryText)
                    if let value {
                        Text(value).foregroundColor(PopoverVisualStyle.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(PopoverVisualStyle.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(PopoverVisualStyle.Typography.body)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.bottom, PopoverVisualStyle.Spacing.sm)
            }
        }
    }
}

// MARK: - Segmented control

/// One option inside a segmented track.
///
/// Selection is signalled by hue (accent tint plus accent label) rather than by
/// a slightly darker grey, which previously left only a 0.04 alpha difference
/// between the selected pill and its own container.
struct PopoverSegmentedOption: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let isEnabled: Bool
    var accent: Color = PopoverVisualStyle.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.bodyStrong)
                .foregroundColor(isSelected ? accent : PopoverVisualStyle.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background {
                    RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.control - 2, style: .continuous)
                        .fill(isSelected ? accent.opacity(0.16) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled || isSelected ? 1 : 0.42)
    }
}

extension View {
    /// Track behind a row of `PopoverSegmentedOption`s.
    func popoverSegmentedTrack() -> some View {
        padding(2)
            .popoverSurface(radius: PopoverVisualStyle.Radius.control)
    }
}

// MARK: - Badge

/// Tinted pill used for proxy route, IP version, risk and property labels.
struct PopoverBadge: View {
    let text: String
    var color: Color = PopoverVisualStyle.secondaryText

    var body: some View {
        Text(text)
            .font(PopoverVisualStyle.Typography.captionStrong)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.badge, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }
}

// MARK: - Banner

/// Tinted message row with an optional trailing action.
///
/// Banners live inside the page that owns the problem, never as a permanent
/// strip at the top of the panel.
struct PopoverBanner<Action: View>: View {
    let message: String
    var tone: PopoverStatusTone = .caution
    var icon: String?
    var lineLimit = 3
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopoverVisualStyle.Spacing.sm) {
            Image(systemName: icon ?? defaultIcon)
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopoverVisualStyle.Spacing.xs)
            action()
        }
        .font(PopoverVisualStyle.Typography.caption)
        .foregroundColor(tint)
        .padding(PopoverVisualStyle.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.card, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }

    private var tint: Color {
        PopoverVisualStyle.color(for: tone)
    }

    private var defaultIcon: String {
        tone == .negative ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }
}

extension PopoverBanner where Action == EmptyView {
    init(message: String, tone: PopoverStatusTone = .caution, icon: String? = nil, lineLimit: Int = 3) {
        self.init(message: message, tone: tone, icon: icon, lineLimit: lineLimit, action: { EmptyView() })
    }
}

// MARK: - Action button

/// Full-width setup or repair action.
///
/// It sits on the neutral surface with an accent label rather than an accent
/// fill: an accent-filled rectangle is reserved for the current selection, so a
/// page with two repair actions does not read as two primary controls.
struct PopoverActionButton: View {
    let title: String
    let icon: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.bodyStrong)
                .foregroundColor(PopoverVisualStyle.accent)
                .frame(maxWidth: .infinity, minHeight: 28)
                .popoverSurface(radius: PopoverVisualStyle.Radius.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

extension View {
    /// Animates digit changes where the platform supports it.
    @ViewBuilder
    func popoverNumericTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }
}

extension PopoverStatusTone {
    var factState: PopoverFactState {
        switch self {
        case .positive: return .ok
        case .caution: return .warning
        case .negative: return .fault
        case .neutral: return .unknown
        }
    }
}

// MARK: - Meters

/// Horizontal proportion bar for quota, share and score.
///
/// `fraction` is pre-clamped by `PopoverMeter.fraction(_:of:)`, which returns
/// `nil` when a proportion is undefined (no limit, or nothing to compare
/// against) so callers can omit the bar entirely rather than draw a misleading
/// empty one.
struct PopoverMeter: View {
    let fraction: Double
    var tint: Color = PopoverVisualStyle.meterFill
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(PopoverVisualStyle.meterTrack)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }

    /// `nil` when the proportion is undefined: a zero or negative total means
    /// "unlimited" or "nothing measured yet", neither of which is 0%.
    static func fraction(_ value: some BinaryInteger, of total: some BinaryInteger) -> Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(value) / Double(total)))
    }

    /// Floating-point variant for speeds.
    static func fraction(_ value: Double, of total: Double) -> Double? {
        guard total > 0, value.isFinite, total.isFinite else { return nil }
        return min(1, max(0, value / total))
    }
}

/// Compact line chart over a fixed-length sample window.
///
/// Scales to the window's own maximum so idle periods stay flat instead of
/// amplifying noise into a busy-looking chart.
struct PopoverSparkline: View {
    let samples: [Double]
    var tint: Color = PopoverVisualStyle.meterFill
    var height: CGFloat = 18

    /// Below this the window is too short to read as a trend, and a two-point
    /// line looks like a stray rule rather than a chart.
    static let minimumSamples = 6

    var body: some View {
        GeometryReader { geometry in
            let points = Self.points(samples, in: geometry.size)
            if !points.isEmpty {
                ZStack {
                    Path { path in
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                        path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(tint.opacity(0.12))

                    Path { path in path.addLines(points) }
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    static func points(_ samples: [Double], in size: CGSize) -> [CGPoint] {
        guard samples.count >= minimumSamples else { return [] }
        let peak = samples.max() ?? 0
        guard peak > 0 else { return [] }

        // Scale against the peak plus headroom. Without it a steady rate
        // normalises to 1.0 at every point and draws a hard line along the top
        // edge, which reads as a divider instead of a trend.
        let ceiling = peak * 1.25
        let step = size.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { index, value in
            let normalized = min(1, max(0, value / ceiling))
            return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - normalized))
        }
    }
}
