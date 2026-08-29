import Cocoa

// MARK: - 自定义菜单栏视图（像素级精确控制位置）

/// 自定义绘制视图 — 左侧图标 + 右侧两行速度文字，完全居中
class StatusBarView: NSView {
    var uploadText: String = "0B/s"
    var downloadText: String = "0B/s"
    var isPanelOpen: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    // 动态计算图标（每次绘制时根据深浅色模式采用 headerTextColor）
    private var icon: NSImage? {
        guard let img = NSImage(systemSymbolName: "network", accessibilityDescription: "NetBar") else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(.init(paletteColors: [.headerTextColor]))
        return img.withSymbolConfiguration(config)
    }

    private let textFont = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .medium)

    // MARK: - 尺寸常量

    /// `network` 在 pointSize 13 下的自然尺寸就是 16×16；此前画进 14pt 的方框里，
    /// 等于把符号重新缩放了一次，边缘发虚。
    private static let iconSize: CGFloat = 16
    private static let iconX: CGFloat = 3
    private static let iconTextGap: CGFloat = 3
    /// 常见速度的排版宽度：实测 "7K/s" 20.3pt、"12K/s" 26.2pt、"1.2M/s" 31.1pt、
    /// "999K/s" 32.2pt。取 32 覆盖到常见峰值，更高的速度由 `fittingFont` 缩排。
    private static let textWidth: CGFloat = 32
    private static let rightPadding: CGFloat = 2
    private static let barHeight: CGFloat = 22

    /// 状态项宽度的唯一来源，由布局常量算出。
    ///
    /// 此前视图按 64 计算固有宽度，而 `StatusBarController` 又把状态项和视图
    /// 都硬编码成 72，两个数字互不知情，多出来的部分成了右侧死区。
    static let preferredWidth: CGFloat =
        iconX + iconSize + iconTextGap + textWidth + rightPadding

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredWidth, height: Self.barHeight)
    }

    func update(upload: String, download: String) {
        self.uploadText = upload
        self.downloadText = download
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let h = bounds.height  // 菜单栏默认通常是 22
        if isPanelOpen {
            let highlightRect = bounds.insetBy(dx: 2, dy: 2)
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(
                roundedRect: highlightRect,
                xRadius: highlightRect.height / 2,
                yRadius: highlightRect.height / 2
            ).fill()
        }

        // ---------- 1. 绘制图标 ----------
        // 绝对数值定点垂直居中: (22 - 14) / 2 = 4
        let iconY = (h - Self.iconSize) / 2
        let iconRect = NSRect(x: Self.iconX, y: iconY, width: Self.iconSize, height: Self.iconSize)
        icon?.draw(in: iconRect)

        // ---------- 2. 绘制文字 ----------
        // 文字紧贴图标左对齐。此前它右对齐到一个 38pt 固定框内，常见的
        // "7K/s"（实测 20.3pt）因此被推到距图标 21.7pt 的位置——空隙比图标本身
        // 还宽。左对齐让富余量落到尾部，读作与下一个菜单栏项之间的间距，
        // 同时图标位置恒定，不会随速度跳动。
        let textX = Self.iconX + Self.iconSize + Self.iconTextGap
        let available = bounds.width - textX - Self.rightPadding
        let font = fittingFont(for: [uploadText, downloadText], within: available)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.headerTextColor
        ]

        // 绝对坐标控制基线高度（完美规避系统自带行高的排版偏移）
        NSAttributedString(string: uploadText, attributes: textAttrs)
            .draw(at: NSPoint(x: textX, y: 11.5))
        NSAttributedString(string: downloadText, attributes: textAttrs)
            .draw(at: NSPoint(x: textX, y: 1.5))
    }

    /// 罕见的极高速度（例如 "1023.9M/s" 实测 49pt）超出可用宽度时缩排而不是裁掉，
    /// 避免把数字截断成看不懂的样子。
    private func fittingFont(for strings: [String], within available: CGFloat) -> NSFont {
        let widest = strings
            .map { NSAttributedString(string: $0, attributes: [.font: textFont]).size().width }
            .max() ?? 0
        guard widest > available, widest > 0, available > 0 else { return textFont }
        // 量化到 0.5pt。速度在阈值附近来回浮动时，连续缩放会让字号持续抖动；
        // 取整后只有跨越档位才会变化。
        let scaled = textFont.pointSize * (available / widest)
        let quantized = (scaled * 2).rounded(.down) / 2
        return NSFont.monospacedDigitSystemFont(ofSize: max(7, quantized), weight: .medium)
    }
}
