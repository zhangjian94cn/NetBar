import Cocoa
import SwiftUI

// MARK: - 菜单栏控制器

/// 菜单栏控制器 — 管理 NSStatusItem 和原生风格浮层面板
class StatusBarController: NSObject, NSWindowDelegate {
    private let panelWidth: CGFloat = 380
    private let panelFallbackHeight: CGFloat = 420
    private let panelMinHeight: CGFloat = 280
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
        let contentView = MenuPopoverView(
            networkMonitor: coordinator.networkMonitor,
            proxyDetector: coordinator.proxyDetector,
            processTrafficMonitor: coordinator.processTrafficMonitor,
            networkInfoProvider: coordinator.networkInfoProvider,
            vpsTrafficMonitor: coordinator.vpsTrafficMonitor,
            appIconResolver: coordinator.appIconResolver,
            coordinator: coordinator
        )
        let controller = NSHostingController(rootView: contentView)
        return controller
    }

    /// 根据状态栏按钮所在屏幕和 SwiftUI 内容尺寸计算面板高度。
    private func panelSize(for controller: NSViewController, relativeTo button: NSStatusBarButton) -> NSSize {
        let fittingHeight = fittingContentHeight(for: controller)
        let availableHeight = availablePanelHeight(below: button)
        let height = min(max(fittingHeight, panelMinHeight), availableHeight)
        return NSSize(width: panelWidth, height: height)
    }

    private func fittingContentHeight(for controller: NSViewController) -> CGFloat {
        controller.view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelFallbackHeight)
        controller.view.layoutSubtreeIfNeeded()

        let fittingHeight = controller.view.fittingSize.height
        guard fittingHeight.isFinite, fittingHeight > 0 else {
            return panelFallbackHeight
        }
        return fittingHeight
    }

    private func availablePanelHeight(below button: NSStatusBarButton) -> CGFloat {
        guard let window = button.window,
              let screen = window.screen else {
            return panelFallbackHeight
        }

        let availableBelowMenuBar = screen.visibleFrame.height - screenEdgeMargin
        return max(panelMinHeight, availableBelowMenuBar)
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
        }
    }

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
