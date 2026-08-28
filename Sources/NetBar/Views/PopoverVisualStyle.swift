import AppKit
import SwiftUI

/// A deliberately small set of shared presentation tokens for the menu popover.
/// Business cards keep their own semantic tint; this type only aligns spacing,
/// typography, controls, and native macOS surfaces.
enum PopoverVisualStyle {
    enum Radius {
        static let control: CGFloat = 9
        static let card: CGFloat = 11
        static let shell: CGFloat = 18
    }

    enum Typography {
        static let title = Font.system(size: 16, weight: .bold)
        static let section = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 11, weight: .regular)
        static let bodyStrong = Font.system(size: 11, weight: .semibold)
        static let caption = Font.system(size: 10, weight: .regular)
        static let captionStrong = Font.system(size: 10, weight: .semibold)
        static let data = Font.system(size: 10, weight: .medium, design: .monospaced)
        static let metric = Font.system(size: 19, weight: .semibold, design: .monospaced)
    }

    static let healthy = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let fault = Color(nsColor: .systemRed)
    static let ipAccent = Color(nsColor: .systemIndigo)
    static let vpsAccent = Color(nsColor: .systemCyan)

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.65)
    static let hairline = Color.primary.opacity(0.09)
    static let groupFill = Color.primary.opacity(0.035)
    static let controlFill = Color.primary.opacity(0.07)
    static let selectedFill = Color.primary.opacity(0.11)

    static func color(for tone: PopoverStatusTone) -> Color {
        switch tone {
        case .positive: return healthy
        case .caution: return warning
        case .negative: return fault
        case .neutral: return secondaryText
        }
    }

    static func statusFill(for tone: PopoverStatusTone) -> Color {
        color(for: tone).opacity(tone == .positive ? 0.10 : 0.085)
    }
}

private struct PopoverGroupModifier: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.card, style: .continuous)
                    .fill(tint?.opacity(0.075) ?? PopoverVisualStyle.groupFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.card, style: .continuous)
                    .stroke((tint ?? .primary).opacity(0.08), lineWidth: 0.5)
            }
    }
}

extension View {
    func popoverGroup(tint: Color? = nil) -> some View {
        modifier(PopoverGroupModifier(tint: tint))
    }
}

struct PopoverSegmentedOption: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let isEnabled: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.bodyStrong)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background {
                    RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.control, style: .continuous)
                        .fill(isSelected ? accent : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled || isSelected ? 1 : 0.42)
    }
}
