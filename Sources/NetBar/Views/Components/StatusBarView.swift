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
    
    // 尺寸常量
    private let iconSize: CGFloat = 14
    private let iconX: CGFloat = 4
    private let iconTextGap: CGFloat = 4
    private let maxTextWidth: CGFloat = 38
    private let rightPadding: CGFloat = 4
    private let totalWidth: CGFloat = 64

    override var intrinsicContentSize: NSSize {
        return NSSize(width: totalWidth, height: 22)
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

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.headerTextColor
        ]

        // ---------- 1. 绘制图标 ----------
        // 绝对数值定点垂直居中: (22 - 14) / 2 = 4
        let iconY = (h - iconSize) / 2
        let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        icon?.draw(in: iconRect)

        // ---------- 2. 绘制文字 ----------
        let textX = iconX + iconSize + iconTextGap
        let upStr = NSAttributedString(string: uploadText, attributes: textAttrs)
        let dnStr = NSAttributedString(string: downloadText, attributes: textAttrs)

        // 上传（上行）— 右对齐到 maxTextWidth
        let upWidth = upStr.size().width
        let upDrawX = textX + maxTextWidth - upWidth
        // 绝对坐标控制基线高度（完美规避系统自带行高的排版偏移）
        let upDrawY: CGFloat = 11.5
        upStr.draw(at: NSPoint(x: upDrawX, y: upDrawY))

        // 下载（下行）— 右对齐到 maxTextWidth
        let dnWidth = dnStr.size().width
        let dnDrawX = textX + maxTextWidth - dnWidth
        let dnDrawY: CGFloat = 1.5
        dnStr.draw(at: NSPoint(x: dnDrawX, y: dnDrawY))
    }
}
