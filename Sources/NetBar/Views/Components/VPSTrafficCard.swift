import SwiftUI

/// VPS 流量卡片
struct VPSTrafficCard: View {
    let vps: VPSTrafficMonitor.VPSTraffic

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行
            HStack {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.cyan)
                Text(vps.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.cyan.opacity(0.1)))
                
                Spacer()
                
                Text("⟳ \(vps.lastUpdatedText)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            // 流量统计
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.green)
                        Text("上传")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Text(vps.formattedUpload)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.blue)
                        Text("下载")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Text(vps.formattedDownload)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("总计")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    HStack(spacing: 3) {
                        Text(vps.formattedTotal)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text("/ \(vps.formattedLimit)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            // 错误提示
            if let error = vps.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                }
            }

            // 客户端
            if !vps.clients.isEmpty {
                Divider()
                ForEach(vps.clients) { client in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(client.isOnline ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(client.email)
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text("\(Formatters.formatBytes(client.upload)) ↑")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("\(Formatters.formatBytes(client.download)) ↓")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.cyan.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.1), lineWidth: 0.5))
    }
}
