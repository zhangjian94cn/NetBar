import Cocoa
import SwiftUI

// MARK: - 菜单栏控制器

/// 菜单栏控制器 — 管理 NSStatusItem 和 Popover
class StatusBarController: NSObject, NSPopoverDelegate {
    private let popoverWidth: CGFloat = 380
    private let popoverPreferredHeight: CGFloat = 520
    private let popoverVerticalMargin: CGFloat = 96

    private var statusItem: NSStatusItem!
    private var statusBarView: StatusBarView!
    private var popover: NSPopover!
    private let coordinator: MonitorCoordinator
    private var updateTimer: Timer?
    private var eventMonitor: Any?

    init(coordinator: MonitorCoordinator) {
        self.coordinator = coordinator
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
        popover.contentSize = NSSize(width: popoverWidth, height: popoverPreferredHeight)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    private func makePopoverContentViewController(height: CGFloat) -> NSViewController {
        let contentView = MenuPopoverView(
            networkMonitor: coordinator.networkMonitor,
            proxyDetector: coordinator.proxyDetector,
            processTrafficMonitor: coordinator.processTrafficMonitor,
            networkInfoProvider: coordinator.networkInfoProvider,
            vpsTrafficMonitor: coordinator.vpsTrafficMonitor,
            appIconResolver: coordinator.appIconResolver,
            contentHeight: height
        )
        let controller = NSHostingController(rootView: contentView)
        controller.view.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: height)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func currentPopoverHeight(relativeTo button: NSStatusBarButton) -> CGFloat {
        guard let screen = button.window?.screen else {
            return popoverPreferredHeight
        }
        let availableHeight = screen.visibleFrame.height - popoverVerticalMargin
        return min(popoverPreferredHeight, max(360, availableHeight))
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
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        let height = currentPopoverHeight(relativeTo: button)
        popover.contentSize = NSSize(width: popoverWidth, height: height)
        popover.contentViewController = makePopoverContentViewController(height: height)

        DispatchQueue.main.async { [weak self, weak button] in
            guard let self = self, let button = button, !self.popover.isShown else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
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
