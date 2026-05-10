import Foundation

/// 应用级错误类型 — 结构化的错误定义
/// 用于替代静默忽略错误的 `catch { return nil }` 模式
enum AppError: LocalizedError {

    // MARK: - 存储
    case storageWriteFailed(path: String, underlying: Error)
    case storageReadFailed(path: String, underlying: Error)

    // MARK: - VPS
    case vpsLoginFailed(host: String)
    case vpsDataFetchFailed(host: String)

    // MARK: - Mihomo
    case mihomoUnavailable
    case mihomoDecodeFailed(underlying: Error)

    // MARK: - 网络
    case processSpawnFailed(command: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .storageWriteFailed(let path, let err):
            return "流量数据写入失败: \(path) — \(err.localizedDescription)"
        case .storageReadFailed(let path, let err):
            return "流量数据读取失败: \(path) — \(err.localizedDescription)"
        case .vpsLoginFailed(let host):
            return "VPS 登录失败: \(host)"
        case .vpsDataFetchFailed(let host):
            return "VPS 数据获取失败: \(host)"
        case .mihomoUnavailable:
            return "Mihomo 服务不可用"
        case .mihomoDecodeFailed(let err):
            return "Mihomo 数据解析失败: \(err.localizedDescription)"
        case .processSpawnFailed(let cmd, let err):
            return "进程启动失败: \(cmd) — \(err.localizedDescription)"
        }
    }
}
