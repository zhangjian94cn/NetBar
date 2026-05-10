import Foundation

/// 本地化字符串常量 — 集中管理所有用户可见文本
/// 当前为中文硬编码，后续可替换为 NSLocalizedString 实现多语言
///
/// 使用方式：`Text(L10n.Tab.realtime)` 替代 `Text("实时活跃")`
enum L10n {

    // MARK: - 标签栏

    enum Tab {
        static let realtime = "实时活跃"
        static let cumulative = "累计流量"
    }

    // MARK: - 速度面板

    enum Speed {
        static let download = "下载"
        static let upload = "上传"
    }

    // MARK: - 时间段

    enum Period {
        static let oneMinute = "1 分钟"
        static let fiveMinutes = "5 分钟"
        static let oneHour = "1 小时"
        static let sinceStart = "启动至今"
        static let today = "今天"
        static let sevenDays = "7 天"
        static let thirtyDays = "30 天"
        static let thisMonth = "本月"
    }

    // MARK: - 代理状态

    enum Proxy {
        static let direct = "直连"
        static let proxied = "代理"
        static let mixed = "混合"
        static let unknown = "—"

        static let systemDirect = "系统直连"
        static let systemProxyOn = "系统代理已开启"
        static let systemProxyAndTUN = "系统代理 + TUN 已开启"
        static let tunActive = "TUN 已接管"
    }

    // MARK: - 表格

    enum Table {
        static let app = "应用"
        static let route = "路由"
        static let downloadHeader = "↓ 下载"
        static let uploadHeader = "↑ 上传"
        static let noActiveApps = "暂无活跃应用"
        static let noTrafficRecords = "暂无流量记录"
    }

    // MARK: - VPS

    enum VPS {
        static let total = "总计"
        static let unlimited = "∞"
        static let notConnected = "未连接"
        static let noVPSConfigured = "未配置 VPS 服务器"
        static let addVPSHint = "添加 VPS 后可在菜单栏查看流量统计"
        static let addVPS = "添加 VPS"
        static let unknownProxyApp = "未知代理应用"
    }

    // MARK: - 底栏

    enum Footer {
        static let refresh = "刷新"
        static let settings = "设置"
        static let quit = "退出"
    }

    // MARK: - 设置窗口

    enum Settings {
        static let title = "NetBar 设置"
        static let general = "通用"
        static let proxy = "代理"
        static let vpsMonitor = "VPS 监控"
        static let launchAtLogin = "开机自动启动"
        static let refreshInterval = "刷新间隔"
        static let version = "版本"
        static let build = "构建"
        static let basic = "基本"
        static let about = "关于"
        static let save = "保存"
        static let cancel = "取消"

        // Mihomo
        static let mihomoSocketPath = "Socket 路径"
        static let mihomoControllerURL = "Controller URL"
        static let mihomoSecret = "Secret"
        static let mihomoFooter = "Mihomo 代理核心的本地连接信息。如果使用 Clash Verge，Socket 路径通常为 /tmp/verge/verge-mihomo.sock"

        // VPS Editor
        static let name = "名称"
        static let host = "主机"
        static let port = "端口"
        static let username = "用户名"
        static let password = "密码"
        static let useTLS = "使用 TLS (HTTPS)"
    }

    // MARK: - 时间

    enum Time {
        static func secondsAgo(_ n: Int) -> String { "\(n)s 前" }
        static func minutesAgo(_ n: Int) -> String { "\(n)m 前" }
        static func hoursAgo(_ n: Int) -> String { "\(n)h 前" }

        static let second = "秒"
    }

    // MARK: - 错误

    enum Error {
        static let storageWriteFailed = "流量数据写入失败"
        static let storageReadFailed = "流量数据读取失败"
        static let vpsLoginFailed = "VPS 登录失败"
        static let vpsDataFetchFailed = "VPS 数据获取失败"
        static let mihomoUnavailable = "Mihomo 服务不可用"
        static let mihomoDecodeFailed = "Mihomo 数据解析失败"
        static let processSpawnFailed = "进程启动失败"
        static let launchAtLoginFailed = "开机自启设置失败"
        static let vpsMonitorSkipped = "未配置 VPS 信息，VPS 流量监控跳过"
    }
}
