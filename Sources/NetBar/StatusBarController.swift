import Cocoa
import SwiftUI

// MARK: - 自定义菜单栏视图（像素级精确控制位置）

/// 自定义绘制视图 — 左侧图标 + 右侧两行速度文字，完全居中
class StatusBarView: NSView {
    var uploadText: String = "0B/s"
    var downloadText: String = "0B/s"

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

// MARK: - 菜单栏控制器

/// 菜单栏控制器 — 管理 NSStatusItem 和 Popover
class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var statusBarView: StatusBarView!
    private var popover: NSPopover!
    private var networkMonitor: NetworkMonitor
    private var proxyDetector: ProxyDetector
    private var processTrafficMonitor: ProcessTrafficMonitor
    private var networkInfoProvider: NetworkInfoProvider
    private var appIconResolver: AppIconResolver
    private var updateTimer: Timer?
    private var eventMonitor: Any?

    init(networkMonitor: NetworkMonitor, proxyDetector: ProxyDetector,
         processTrafficMonitor: ProcessTrafficMonitor,
         networkInfoProvider: NetworkInfoProvider,
         appIconResolver: AppIconResolver) {
        self.networkMonitor = networkMonitor
        self.proxyDetector = proxyDetector
        self.processTrafficMonitor = processTrafficMonitor
        self.networkInfoProvider = networkInfoProvider
        self.appIconResolver = appIconResolver

        super.init()

        setupStatusItem()
        setupPopover()
        startUpdatingTitle()
        setupEventMonitor()
    }

    private func setupStatusItem() {
        // 固定宽度避免抖动
        statusItem = NSStatusBar.system.statusItem(withLength: 72)

        // 使用自定义视图替代默认 button.title
        statusBarView = StatusBarView(frame: NSRect(x: 0, y: 0, width: 72, height: 22))

        if let button = statusItem.button {
            // 将自定义视图添加到 button 内部
            button.addSubview(statusBarView)
            statusBarView.frame = button.bounds
            statusBarView.autoresizingMask = [.width, .height]

            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.behavior = .transient
        popover.animates = true

        let contentView = MenuPopoverView(
            networkMonitor: networkMonitor,
            proxyDetector: proxyDetector,
            processTrafficMonitor: processTrafficMonitor,
            networkInfoProvider: networkInfoProvider,
            appIconResolver: appIconResolver
        )
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    private func startUpdatingTitle() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.updateTitle()
            }
        }
        if let timer = updateTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateTitle() {
        let speed = networkMonitor.currentSpeed
        statusBarView.update(
            upload: speed.compactUpload,
            download: speed.compactDownload
        )
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let self = self, self.popover.isShown {
                self.closePopover()
            }
        }
    }

    deinit {
        updateTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
