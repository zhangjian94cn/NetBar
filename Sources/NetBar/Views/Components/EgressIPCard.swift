import SwiftUI

extension RiskTier {
    /// 六档 → PopoverKit 三档业务色（档位文字补足六档语义，不新增第六种颜色）。
    var tint: Color {
        switch self {
        case .extremelyPure, .pure: return PopoverVisualStyle.healthy
        case .neutral, .slightRisk: return PopoverVisualStyle.warning
        case .moderateRisk, .extremeRisk: return PopoverVisualStyle.fault
        }
    }
}

struct EgressIPCard: View {
    @ObservedObject var monitor: EgressIPMonitor

    var body: some View {
        PopoverCard(
            icon: "globe.asia.australia.fill",
            title: "公网出口 IP"
        ) {
            if monitor.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else if let info = monitor.info {
                Text(info.lastUpdatedText)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.tertiaryText)
            }
        } content: {
            if let info = monitor.info {
                loaded(info)
            } else if let error = monitor.errorMessage {
                PopoverBanner(message: error, lineLimit: 2)
            } else {
                Text("正在检测当前公网出口…")
                    .font(PopoverVisualStyle.Typography.body)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func loaded(_ info: EgressIPInfo) -> some View {
        VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.sm) {
            HStack(spacing: PopoverVisualStyle.Spacing.sm) {
                Text(info.ip)
                    .font(PopoverVisualStyle.Typography.metric)
                    .foregroundColor(PopoverVisualStyle.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                PopoverBadge(text: info.ipVersion.displayName)

                Spacer(minLength: PopoverVisualStyle.Spacing.xs)

                PopoverBadge(text: info.riskLabel, color: riskColor(info))
            }

            if let risk = info.ipRisk,
               let fraction = PopoverMeter.fraction(risk, of: 100) {
                PopoverMeter(fraction: fraction, tint: riskColor(info))
            }

            VStack(alignment: .leading, spacing: 0) {
                if let location = info.locationDisplay, !location.isEmpty {
                    PopoverFactRow(title: "位置", value: location, compact: true)
                }
                if let asn = info.asn, !asn.isEmpty {
                    PopoverFactRow(title: "ASN", value: asn, compact: true)
                }
                if let org = info.org, !org.isEmpty {
                    PopoverFactRow(title: "组织", value: org, compact: true)
                }
                if let sharedUsers = info.sharedUsersText {
                    PopoverFactRow(title: "共享人数", value: sharedUsers, compact: true)
                }
                if let aiDetection = info.aiDetectionText {
                    PopoverFactRow(title: "大模型检测", value: aiDetection, compact: true)
                }
            }

            if info.ipTypeText != nil || info.isIDC != nil || info.isNative != nil || info.orgType != nil {
                HStack(spacing: PopoverVisualStyle.Spacing.xs + 2) {
                    if let ipType = info.ipTypeText {
                        PopoverBadge(
                            text: ipType,
                            color: ipType.contains("IDC") ? PopoverVisualStyle.warning : PopoverVisualStyle.healthy
                        )
                    } else if let isIDC = info.isIDC {
                        PopoverBadge(
                            text: isIDC ? "IDC" : "非 IDC",
                            color: isIDC ? PopoverVisualStyle.warning : PopoverVisualStyle.healthy
                        )
                    }
                    if let isNative = info.isNative {
                        PopoverBadge(
                            text: isNative ? "原生" : "非原生",
                            color: isNative ? PopoverVisualStyle.healthy : PopoverVisualStyle.warning
                        )
                    }
                    if let orgType = info.orgType, !orgType.isEmpty {
                        PopoverBadge(text: orgType.uppercased())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("地理位置来自 IP 数据库，可能与真实物理位置不一致。来源 \(info.source)")
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let reportURL = fullReportURL(info.ip) {
                    Link("在 ping0.cc 查看完整报告", destination: reportURL)
                        .font(PopoverVisualStyle.Typography.caption)
                }
            }
        }
    }

    private func riskColor(_ info: EgressIPInfo) -> Color {
        info.riskTier?.tint ?? PopoverVisualStyle.secondaryText
    }

    private func fullReportURL(_ ip: String) -> URL? {
        URL(string: "https://ping0.cc/ip/\(ip)")
    }
}
