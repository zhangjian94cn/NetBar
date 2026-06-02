import Cocoa
import SwiftUI

/// 应用入口 — 纯菜单栏应用，无 Dock 图标
@main
struct NetBarApp {
    // 保持 AppDelegate 的强引用，防止被 ARC 释放
    // （NSApplication.delegate 是 weak 属性）
    static let appDelegate = AppDelegate()

    static func main() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.zjah.NetBar")
            .first { $0.processIdentifier != currentPID }
        guard existingApp == nil else { return }

        let app = NSApplication.shared
        // 设置为 accessory 模式（不显示 Dock 图标）
        app.setActivationPolicy(.accessory)

        app.delegate = appDelegate

        app.run()
    }
}
