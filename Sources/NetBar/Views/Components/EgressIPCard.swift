import SwiftUI

struct EgressIPCard: View {
    @ObservedObject var monitor: EgressIPMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "globe.asia.australia.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(PopoverVisualStyle.ipAccent)
                Text("公网出口 IP")
                    .font(PopoverVisualStyle.Typography.section)

                Spacer()

                if monitor.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else if let info = monitor.info {
                    Text("⟳ \(info.lastUpdatedText)")
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let info = monitor.info {
                HStack(spacing: 8) {
                    Text(info.ip)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(info.ipVersion.displayName)
                        .font(PopoverVisualStyle.Typography.captionStrong)
                        .foregroundColor(PopoverVisualStyle.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))

                    Spacer()

                    riskBadge(info)
                }

                VStack(alignment: .leading, spacing: 3) {
                    infoLine(label: "位置", value: info.locationDisplay)
                    infoLine(label: "ASN", value: info.asn)
                    infoLine(label: "组织", value: info.org)
                }

                if info.ipRisk != nil || info.isIDC != nil || info.isNative != nil {
                    HStack(spacing: 6) {
                        if let isIDC = info.isIDC {
                            propertyBadge(isIDC ? "IDC" : "非 IDC", color: isIDC ? PopoverVisualStyle.warning : PopoverVisualStyle.healthy)
                        }
                        if let isNative = info.isNative {
                            propertyBadge(isNative ? "原生" : "非原生", color: isNative ? PopoverVisualStyle.healthy : PopoverVisualStyle.warning)
                        }
                        if let orgType = info.orgType, !orgType.isEmpty {
                            propertyBadge(orgType.uppercased(), color: .secondary)
                        }
                    }
                }

                Text("地理位置来自 IP 数据库，可能与真实物理位置不一致。")
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text("来源: \(info.source)")
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.tertiaryText)
            } else if let error = monitor.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(PopoverVisualStyle.warning)
                    Text(error)
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.warning)
                        .lineLimit(2)
                }
            } else {
                Text("正在检测当前公网出口...")
                    .font(PopoverVisualStyle.Typography.body)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
            }
        }
        .padding(12)
        .popoverGroup(tint: PopoverVisualStyle.ipAccent)
    }

    private func riskBadge(_ info: EgressIPInfo) -> some View {
        Text(info.riskLabel)
            .font(PopoverVisualStyle.Typography.captionStrong)
            .foregroundColor(riskColor(info))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(riskColor(info).opacity(0.10)))
    }

    @ViewBuilder
    private func infoLine(label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(label):")
                    .font(PopoverVisualStyle.Typography.captionStrong)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
                Text(value)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func propertyBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PopoverVisualStyle.Typography.captionStrong)
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.10)))
    }

    private func riskColor(_ info: EgressIPInfo) -> Color {
        guard let risk = info.ipRisk else {
            return PopoverVisualStyle.secondaryText
        }
        if risk <= 25 { return PopoverVisualStyle.healthy }
        if risk <= 50 { return PopoverVisualStyle.warning }
        return PopoverVisualStyle.fault
    }
}
