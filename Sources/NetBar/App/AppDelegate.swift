import Cocoa
import SwiftUI

/// AppDelegate — 应用程序代理，管理生命周期
class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = MonitorCoordinator()
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NettopParser.sweepOrphanedNettopProcesses()
        configureMainMenu()
        coordinator.startAll()

        statusBarController = StatusBarController(
            coordinator: coordinator
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the installed app again exposes its current facts, without
        // selecting a mode or acquiring DNS on the user's behalf.
        statusBarController?.showPanel()
        return false
    }

    private var terminationPending = false
    private var terminationReplied = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        coordinator.clashNetworkModeController.releaseDNSForTermination {
            self.finishTermination(sender)
        }
        // A stalled UI/backend cannot prevent quitting forever. The independent DNS
        // guardian owns recovery after process exit and never changes Clash state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopAll()
        NettopParser.terminateAllRunningChildren()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "NetBar")
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit NetBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
