import Foundation

/// 统一的格式化工具集 — 消除项目中多处重复的 formatBytes / formatSpeed 实现
enum Formatters {

    // MARK: - 字节数格式化

    /// 格式化字节数为人类可读字符串 (B / KB / MB / GB)
    static func formatBytes(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return String(format: "%.0f B", b) }
        else if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        else if b < 1024 * 1024 * 1024 { return String(format: "%.2f MB", b / (1024 * 1024)) }
        else { return String(format: "%.2f GB", b / (1024 * 1024 * 1024)) }
    }

    // MARK: - 速度格式化

    /// 标准速度格式 (B/s / KB/s / MB/s / GB/s)
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

    /// 菜单栏紧凑速度格式 (0B/s / 12K/s / 1.2M/s)
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
}
