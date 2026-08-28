import Cocoa
import SwiftUI

// MARK: - 菜单栏控制器

/// 菜单栏控制器 — 管理 NSStatusItem 和原生风格浮层面板
class StatusBarController: NSObject, NSWindowDelegate {
    private let panelWidth: CGFloat = 380
    private let directFullPanelHeight: CGFloat = 540
    private let appStoreLitePanelHeight: CGFloat = 460
    private let panelMinHeight: CGFloat = 420
    private let screenEdgeMargin: CGFloat = 8
    private let panelMenuBarGap: CGFloat = 0

    private var statusItem: NSStatusItem!
    private var statusBarView: StatusBarView!
    private var panel: NSPanel?
    private let coordinator: MonitorCoordinator
    private var updateTimer: Timer?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    init(coordinator: MonitorCoordinator) {
        self.coordinator = coordinator
        super.init()

        setupStatusItem()
        startUpdatingTitle()
        setupEventMonitors()
        #if DEBUG
        if ProcessInfo.processInfo.environment["NETBAR_CAPTURE_POPOVER_PATH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPanel()
            }
        }
        #endif
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

    private func makePopoverContentViewController() -> NSViewController {
        #if DEBUG
        if let rawSection = ProcessInfo.processInfo.environment["NETBAR_CAPTURE_POPOVER_SECTION"],
           let section = PopoverSection(rawValue: rawSection) {
            AppConfig.shared.selectedPopoverSection = section
        }
        #endif
        let contentView = MenuPopoverView(
            networkMonitor: coordinator.networkMonitor,
            proxyDetector: coordinator.proxyDetector,
            processTrafficMonitor: coordinator.processTrafficMonitor,
            networkInfoProvider: coordinator.networkInfoProvider,
            egressIPMonitor: coordinator.egressIPMonitor,
            vpsTrafficMonitor: coordinator.vpsTrafficMonitor,
            appIconResolver: coordinator.appIconResolver,
            networkModeController: coordinator.networkModeController,
            clashOverlayModeController: coordinator.clashOverlayModeController,
            coordinator: coordinator
        )
        let controller = NSHostingController(rootView: contentView)
        #if DEBUG
        if let appearanceName = ProcessInfo.processInfo.environment["NETBAR_CAPTURE_APPEARANCE"] {
            controller.view.appearance = NSAppearance(
                named: appearanceName == "dark" ? .darkAqua : .aqua
            )
        }
        #endif
        return controller
    }

    /// 使用稳定的产品框架高度，避免 Tab 内容变化导致面板尺寸跳动。
    private func panelSize(for controller: NSViewController, relativeTo button: NSStatusBarButton) -> NSSize {
        let availableHeight = availablePanelHeight(below: button)
        let preferredHeight = DistributionFlavor.current == .directFull
            ? directFullPanelHeight
            : appStoreLitePanelHeight
        let minimumHeightThatFits = min(panelMinHeight, availableHeight)
        let height = max(minimumHeightThatFits, min(preferredHeight, availableHeight))
        controller.view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
        controller.view.layoutSubtreeIfNeeded()
        return NSSize(width: panelWidth, height: height)
    }

    private func availablePanelHeight(below button: NSStatusBarButton) -> CGFloat {
        guard let window = button.window,
              let screen = window.screen else {
            return directFullPanelHeight
        }

        let availableBelowMenuBar = screen.visibleFrame.height - screenEdgeMargin
        return max(1, availableBelowMenuBar)
    }

    private func panelFrame(for size: NSSize, relativeTo button: NSStatusBarButton) -> NSRect {
        guard let window = button.window,
              let screen = window.screen else {
            return NSRect(origin: .zero, size: size)
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectInScreen = window.convertToScreen(buttonRectInWindow)
        let preferredX = buttonRectInScreen.midX - size.width / 2
        let minX = screen.visibleFrame.minX + screenEdgeMargin
        let maxX = screen.visibleFrame.maxX - screenEdgeMargin - size.width
        let x = min(max(preferredX, minX), maxX)
        let topY = screen.visibleFrame.maxY - panelMenuBarGap
        let y = max(screen.visibleFrame.minY + screenEdgeMargin, topY - size.height)

        return NSRect(x: x, y: y, width: size.width, height: size.height)
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
        let speed = coordinator.networkMonitor.currentSpeed
        statusBarView.update(
            upload: speed.compactUpload,
            download: speed.compactDownload
        )
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if panel != nil {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, panel == nil else { return }

        DispatchQueue.main.async { [weak self, weak button] in
            guard let self = self, let button = button, self.panel == nil else { return }
            button.layoutSubtreeIfNeeded()
            self.statusBarView.frame = button.bounds

            let controller = self.makePopoverContentViewController()
            let size = self.panelSize(for: controller, relativeTo: button)
            let panel = StatusBarPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )

            panel.delegate = self
            panel.contentViewController = controller
            panel.setFrame(self.panelFrame(for: size, relativeTo: button), display: true)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false

            self.panel = panel
            self.setStatusItemHighlighted(true)
            panel.orderFrontRegardless()
            #if DEBUG
            self.capturePanelForDesignQAIfRequested(panel)
            #endif
        }
    }

    #if DEBUG
    /// Test-only visual QA hook. It never ships in Release or App Store builds.
    private func capturePanelForDesignQAIfRequested(_ panel: NSPanel) {
        guard let path = ProcessInfo.processInfo.environment["NETBAR_CAPTURE_POPOVER_PATH"],
              !path.isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak panel] in
            guard let view = panel?.contentView else { return }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            bitmap.size = bounds.size
            view.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    #endif

    private func closePanel() {
        panel?.close()
        panel = nil
        setStatusItemHighlighted(false)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSPanel === panel {
            panel = nil
            setStatusItemHighlighted(false)
        }
    }

    private func setupEventMonitors() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self = self, self.panel != nil else {
                return event
            }

            if event.type == .keyDown, event.keyCode == 53 {
                self.closePanel()
                return nil
            }

            if self.eventIsInsidePanel(event) || self.eventIsInsideStatusButton(event) {
                return event
            }

            self.closePanel()
            return event
        }
    }

    private func eventIsInsidePanel(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        return event.windowNumber == panel.windowNumber
    }

    private func eventIsInsideStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button,
              let window = button.window,
              event.window === window else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    private func setStatusItemHighlighted(_ highlighted: Bool) {
        statusItem.button?.highlight(highlighted)
        statusBarView.isPanelOpen = highlighted
    }

    deinit {
        updateTimer?.invalidate()
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

private final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
