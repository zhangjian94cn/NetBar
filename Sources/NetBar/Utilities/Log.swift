import os

/// 统一日志系统 — 使用 Apple 原生 os.Logger
/// 可通过 Console.app 或 `log stream --predicate 'subsystem == "com.zjah.NetBar"'` 查看
enum Log {
    private static let subsystem = "com.zjah.NetBar"

    /// 网络速度监控
    static let network = Logger(subsystem: subsystem, category: "network")
    /// 应用流量监控（nettop + mihomo）
    static let traffic = Logger(subsystem: subsystem, category: "traffic")
    /// 持久化存储
    static let storage = Logger(subsystem: subsystem, category: "storage")
    /// VPS 流量监控
    static let vps = Logger(subsystem: subsystem, category: "vps")
    /// 代理/VPN 检测
    static let proxy = Logger(subsystem: subsystem, category: "proxy")
    /// UI & 菜单栏
    static let ui = Logger(subsystem: subsystem, category: "ui")
    /// 配置管理
    static let config = Logger(subsystem: subsystem, category: "config")
}
