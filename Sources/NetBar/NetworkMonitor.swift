import Foundation
import Darwin

/// 网络速度监控器 — 使用 sysctl + NET_RT_IFLIST2 读取网络接口 64 位字节统计
class NetworkMonitor: ObservableObject {

    struct InterfaceStats {
        let name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    struct Speed {
        var download: Double  // bytes/s
        var upload: Double    // bytes/s

        static let zero = Speed(download: 0, upload: 0)

        var formattedDownload: String { Speed.formatSpeed(download) }
        var formattedUpload: String { Speed.formatSpeed(upload) }

        static func formatSpeed(_ bytesPerSec: Double) -> String {
            if bytesPerSec < 1024 {
                return String(format: "%.0f B/s", bytesPerSec)
            } else if bytesPerSec < 1024 * 1024 {
                return String(format: "%.1f KB/s", bytesPerSec / 1024)
            } else if bytesPerSec < 1024 * 1024 * 1024 {
                return String(format: "%.2f MB/s", bytesPerSec / (1024 * 1024))
            } else {
                return String(format: "%.2f GB/s", bytesPerSec / (1024 * 1024 * 1024))
            }
        }

        /// 菜单栏紧凑格式（无前导空格，完全靠系统右对齐）
        static func formatSpeedCompact(_ bytesPerSec: Double) -> String {
            if bytesPerSec < 1024 {
                return String(format: "%.0fB/s", bytesPerSec)
            } else if bytesPerSec < 1024 * 1024 {
                return String(format: "%.0fK/s", bytesPerSec / 1024)
            } else if bytesPerSec < 1024 * 1024 * 1024 {
                return String(format: "%.1fM/s", bytesPerSec / (1024 * 1024))
            } else {
                return String(format: "%.1fG/s", bytesPerSec / (1024 * 1024 * 1024))
            }
        }

        var compactDownload: String { Speed.formatSpeedCompact(download) }
        var compactUpload: String { Speed.formatSpeedCompact(upload) }

        /// 菜单栏紧凑格式
        var menuBarText: String {
            "↑ \(formattedUpload)  ↓ \(formattedDownload)"
        }
    }

    @Published var currentSpeed: Speed = .zero
    @Published var interfaceSpeeds: [String: Speed] = [:]

    private var previousStats: [String: InterfaceStats] = [:]
    private var previousTime: Date = Date()
    private var timer: Timer?

    /// 需要排除的接口前缀
    private let excludedPrefixes = ["lo", "gif", "stf", "ap", "bridge", "XHC", "anpi"]

    init() {}

    func start(interval: TimeInterval = 1.0) {
        // 先获取一次基线数据
        previousStats = fetchInterfaceStats()
        previousTime = Date()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.update()
        }
        // 确保 timer 在 common mode 下运行（避免 UI 阻塞时停止）
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        let now = Date()
        let currentStats = fetchInterfaceStats()
        let elapsed = now.timeIntervalSince(previousTime)

        guard elapsed > 0 else { return }

        var totalDownload: Double = 0
        var totalUpload: Double = 0
        var speeds: [String: Speed] = [:]

        for (name, current) in currentStats {
            if let previous = previousStats[name] {
                // 计数器重置（VPN 断开重连、网络切换等）时跳过本次采样
                let dlBytes = current.bytesIn >= previous.bytesIn
                    ? Double(current.bytesIn - previous.bytesIn)
                    : 0
                let ulBytes = current.bytesOut >= previous.bytesOut
                    ? Double(current.bytesOut - previous.bytesOut)
                    : 0

                let dlSpeed = dlBytes / elapsed
                let ulSpeed = ulBytes / elapsed

                // 过滤掉极端异常值（可能是接口重置）
                if dlSpeed < 10_000_000_000 && ulSpeed < 10_000_000_000 {
                    totalDownload += dlSpeed
                    totalUpload += ulSpeed
                    speeds[name] = Speed(download: dlSpeed, upload: ulSpeed)
                }
            }
        }

        DispatchQueue.main.async {
            self.currentSpeed = Speed(download: totalDownload, upload: totalUpload)
            self.interfaceSpeeds = speeds
        }

        previousStats = currentStats
        previousTime = now
    }

    /// 使用 sysctl + NET_RT_IFLIST2 获取网络接口统计（64 位计数器）
    private func fetchInterfaceStats() -> [String: InterfaceStats] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: Int = 0

        // 第一次调用获取需要的缓冲区大小
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0 else {
            return [:]
        }

        var buf = [UInt8](repeating: 0, count: len)

        // 第二次调用实际获取数据
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else {
            return [:]
        }

        var result: [String: InterfaceStats] = [:]
        var offset = 0

        while offset < len {
            buf.withUnsafeBufferPointer { bufPtr in
                let ptr = bufPtr.baseAddress! + offset
                let ifm = ptr.withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee }
                offset += Int(ifm.ifm_msglen)

                guard ifm.ifm_type == RTM_IFINFO2 else { return }

                let bytesIn = ifm.ifm_data.ifi_ibytes
                let bytesOut = ifm.ifm_data.ifi_obytes

                // 通过 index 获取名称
                let ifIndex = ifm.ifm_index
                var ifName = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(ifIndex), &ifName) != nil {
                    let name = String(cString: ifName)

                    // 过滤 loopback 和其他无用接口
                    let shouldExclude = self.excludedPrefixes.contains { name.hasPrefix($0) }
                    if !shouldExclude {
                        result[name] = InterfaceStats(
                            name: name,
                            bytesIn: bytesIn,
                            bytesOut: bytesOut
                        )
                    }
                }
            }
        }

        return result
    }
}
