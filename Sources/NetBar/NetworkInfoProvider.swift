import Foundation
import SystemConfiguration
import Network

/// 网络环境信息提供器 — Wi-Fi 名称、IP 地址
class NetworkInfoProvider: ObservableObject {

    @Published var wifiSSID: String = "—"
    @Published var localIP: String = "—"

    private var timer: Timer?

    init() {}

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ssid = self?.fetchWiFiSSID() ?? "—"
            let ip = self?.fetchLocalIP() ?? "—"

            DispatchQueue.main.async {
                self?.wifiSSID = ssid
                self?.localIP = ip
            }
        }
    }

    /// 获取当前 Wi-Fi SSID（通过 airport 命令）
    private func fetchWiFiSSID() -> String {
        let process = Process()
        let pipe = Pipe()

        // macOS 14.4+ 推荐用 system_profiler 或 wdutil 获取 SSID
        // ipconfig getsummary en0 是一个较稳定的方式
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        process.arguments = ["getsummary", "en0"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if let output = String(data: data, encoding: .utf8) {
                // 查找 "SSID : xxx" 行
                for line in output.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("SSID :") || trimmed.hasPrefix("SSID:") {
                        let parts = trimmed.components(separatedBy: ":")
                        if parts.count >= 2 {
                            return parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            }
        } catch {}

        return "未连接"
    }

    /// 获取本机 IP 地址（en0 接口）
    private func fetchLocalIP() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return "—"
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let name = String(cString: ptr.pointee.ifa_name)

            // 优先取 en0 的 IPv4 地址
            if name == "en0" && ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var addr = ptr.pointee.ifa_addr.pointee
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: hostname)
                }
            }

            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }

        return "—"
    }
}
