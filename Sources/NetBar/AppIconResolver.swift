import Cocoa

/// 应用图标解析器 — 通过进程名查找对应 .app 的图标
class AppIconResolver {

    /// 图标缓存
    private var iconCache: [String: NSImage] = [:]
    /// 进程名 -> 应用路径缓存
    private var pathCache: [String: String?] = [:]

    /// 默认应用图标
    private let defaultIcon: NSImage = {
        NSWorkspace.shared.icon(for: .applicationBundle)
    }()

    /// 获取应用图标（带缓存）
    func icon(for processName: String) -> NSImage {
        if let cached = iconCache[processName] {
            return cached
        }

        let icon = resolveIcon(for: processName)
        iconCache[processName] = icon
        return icon
    }

    private func resolveIcon(for processName: String) -> NSImage {
        // 策略 1: 通过 NSRunningApplication 查找正在运行的应用
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard let appName = app.localizedName else { continue }
            // 匹配进程名（nettop 会截断名字，比如 "Antigravity Hel" -> "Antigravity Helper"）
            if appName.hasPrefix(processName) || processName.hasPrefix(appName) ||
               appName.lowercased().contains(processName.lowercased()) ||
               processName.lowercased().contains(appName.lowercased()) {
                if let icon = app.icon {
                    return icon
                }
            }
        }

        // 策略 2: 通过 mdfind 搜索 .app bundle
        let cleanName = processName
            .replacingOccurrences(of: " Hel", with: "")  // nettop 截断的 Helper
            .replacingOccurrences(of: " Helper", with: "")
            .replacingOccurrences(of: " Helpe", with: "")

        if let appPath = findAppPath(for: cleanName) {
            return NSWorkspace.shared.icon(forFile: appPath)
        }

        // 策略 3: 尝试常见路径
        let commonPaths = [
            "/Applications/\(cleanName).app",
            "/Applications/\(processName).app",
            "/System/Applications/\(cleanName).app",
            "\(NSHomeDirectory())/Applications/\(cleanName).app",
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }

        return defaultIcon
    }

    /// 通过 mdfind 搜索 .app 路径
    private func findAppPath(for name: String) -> String? {
        if let cached = pathCache[name] {
            return cached
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemKind == 'Application' && kMDItemDisplayName == '\(name)'"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if let output = String(data: data, encoding: .utf8) {
                let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n")
                    .first
                if let p = path, !p.isEmpty {
                    pathCache[name] = p
                    return p
                }
            }
        } catch {}

        pathCache[name] = nil
        return nil
    }

    /// 清除缓存
    func clearCache() {
        iconCache.removeAll()
        pathCache.removeAll()
    }
}
