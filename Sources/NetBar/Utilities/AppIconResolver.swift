import Cocoa
import Combine

/// 应用图标解析器 — 通过进程名查找对应 .app 的图标
final class AppIconResolver: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    /// 图标缓存
    private var iconCache: [String: NSImage] = [:]
    /// 进程名 -> 应用路径缓存
    private var pathCache: [String: String] = [:]
    /// 已确认找不到应用路径的名称
    private var missingPathNames: Set<String> = []
    /// 正在后台解析的进程名，避免重复启动 mdfind
    private var pendingNames: Set<String> = []
    private let lookupQueue = DispatchQueue(label: "com.zjah.NetBar.appIconResolver", qos: .utility)
    private let timeoutQueue = DispatchQueue(label: "com.zjah.NetBar.appIconResolver.timeout", qos: .utility)
    private let mdfindTimeout: TimeInterval = 1.5

    /// 默认应用图标
    private let defaultIcon: NSImage = {
        NSWorkspace.shared.icon(for: .applicationBundle)
    }()

    /// 获取应用图标（非阻塞）。未命中时返回默认图标，并在后台预热真实图标。
    func icon(for processName: String) -> NSImage {
        let normalizedName = normalized(processName)
        guard !normalizedName.isEmpty else { return defaultIcon }

        if let cached = iconCache[normalizedName] {
            return cached
        }

        if let runningIcon = resolveRunningAppIcon(for: normalizedName) {
            iconCache[normalizedName] = runningIcon
            return runningIcon
        }

        enqueuePathLookup(for: normalizedName)
        return defaultIcon
    }

    /// 批量预热可见应用图标。
    func preloadIcons(for processNames: [String]) {
        for processName in processNames {
            _ = icon(for: processName)
        }
    }

    private func resolveRunningAppIcon(for processName: String) -> NSImage? {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard let appName = app.localizedName else { continue }

            if appNameMatches(appName, processName: processName) {
                if let icon = app.icon {
                    return icon
                }
            }
        }

        return nil
    }

    private func enqueuePathLookup(for processName: String) {
        guard !pendingNames.contains(processName) else { return }
        let cleanName = cleaned(processName)
        if let cachedPath = pathCache[cleanName] {
            objectWillChange.send()
            iconCache[processName] = NSWorkspace.shared.icon(forFile: cachedPath)
            return
        }
        if missingPathNames.contains(cleanName) {
            iconCache[processName] = defaultIcon
            return
        }

        pendingNames.insert(processName)
        lookupQueue.async { [weak self] in
            guard let self = self else { return }

            let path = self.findAppPath(for: cleanName, originalName: processName)

            DispatchQueue.main.async {
                self.pendingNames.remove(processName)

                self.objectWillChange.send()
                if let path = path {
                    self.pathCache[cleanName] = path
                    self.iconCache[processName] = NSWorkspace.shared.icon(forFile: path)
                } else {
                    self.missingPathNames.insert(cleanName)
                    self.iconCache[processName] = self.defaultIcon
                }
            }
        }
    }

    private func normalized(_ processName: String) -> String {
        processName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleaned(_ processName: String) -> String {
        processName
            .replacingOccurrences(of: " Hel", with: "")  // nettop 截断的 Helper
            .replacingOccurrences(of: " Helper", with: "")
            .replacingOccurrences(of: " Helpe", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appNameMatches(_ appName: String, processName: String) -> Bool {
        let lowerAppName = appName.lowercased()
        let lowerProcessName = processName.lowercased()

        return appName.hasPrefix(processName) ||
            processName.hasPrefix(appName) ||
            lowerAppName.contains(lowerProcessName) ||
            lowerProcessName.contains(lowerAppName)
    }

    /// 通过常见路径和 mdfind 搜索 .app 路径。只在后台队列调用。
    private func findAppPath(for cleanName: String, originalName: String) -> String? {
        let commonPaths = [
            "/Applications/\(cleanName).app",
            "/Applications/\(originalName).app",
            "/System/Applications/\(cleanName).app",
            "\(NSHomeDirectory())/Applications/\(cleanName).app",
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", cleanName]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let timeoutLock = NSLock()
        var didTimeOut = false
        let timeout = DispatchWorkItem {
            timeoutLock.lock()
            didTimeOut = true
            timeoutLock.unlock()

            if process.isRunning {
                process.terminate()
            }
        }

        do {
            try process.run()
            timeoutQueue.asyncAfter(deadline: .now() + mdfindTimeout, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()

            timeoutLock.lock()
            let timedOut = didTimeOut
            timeoutLock.unlock()

            guard !timedOut else {
                return nil
            }

            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n")
                    .first { path in
                        path.hasSuffix(".app") &&
                            FileManager.default.fileExists(atPath: path)
                }
            }
        } catch {}

        return nil
    }

    /// 清除缓存
    func clearCache() {
        iconCache.removeAll()
        pathCache.removeAll()
        missingPathNames.removeAll()
        pendingNames.removeAll()
        objectWillChange.send()
    }
}
