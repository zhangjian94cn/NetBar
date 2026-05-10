import Foundation

/// Manages NetBar's existing LaunchAgent-based startup mechanism.
enum LaunchAgentManager {
    static let label = "com.netbar.agent"
    static let fileName = "\(label).plist"

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static var defaultProgramPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/NetBar.app/Contents/MacOS/NetBar")
            .path
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? install() : uninstall()
    }

    @discardableResult
    static func install(programPath: String = defaultProgramPath) -> Bool {
        do {
            let directory = launchAgentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try plistXML(programPath: programPath).write(to: launchAgentURL, atomically: true, encoding: .utf8)
            _ = runLaunchctl(arguments: ["unload", launchAgentURL.path])
            return runLaunchctl(arguments: ["load", launchAgentURL.path])
        } catch {
            Log.config.error("LaunchAgent 安装失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func uninstall() -> Bool {
        _ = runLaunchctl(arguments: ["unload", launchAgentURL.path])

        do {
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            return true
        } catch {
            Log.config.error("LaunchAgent 卸载失败: \(error.localizedDescription)")
            return false
        }
    }

    static func plistXML(programPath: String = defaultProgramPath) -> String {
        let escapedProgramPath = xmlEscaped(programPath)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escapedProgramPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>StandardOutPath</key>
            <string>/tmp/netbar.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/netbar.err</string>
        </dict>
        </plist>
        """
    }

    private static func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
