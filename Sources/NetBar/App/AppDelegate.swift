import Cocoa
import SwiftUI

/// AppDelegate — 应用程序代理，管理生命周期
class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = MonitorCoordinator()
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.startAll()

        statusBarController = StatusBarController(
            coordinator: coordinator
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopAll()
    }
}
