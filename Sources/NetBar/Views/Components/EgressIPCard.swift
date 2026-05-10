import SwiftUI

struct EgressIPCard: View {
    @ObservedObject var monitor: EgressIPMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.indigo)
                Text("出口 IP")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.indigo.opacity(0.1)))

                Spacer()

                if monitor.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else if let info = monitor.info {
                    Text("⟳ \(info.lastUpdatedText)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }

            if let info = monitor.info {
                HStack(spacing: 8) {
                    Text(info.ip)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(info.ipVersion.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))

                    Spacer()

                    riskBadge(info)
                }

                HStack(spacing: 6) {
                    if let location = info.location, !location.isEmpty {
                        Text(location)
                    }
                    if let asn = info.asn, !asn.isEmpty {
                        Text(asn)
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)

                if info.ipRisk != nil || info.isIDC != nil || info.isNative != nil {
                    HStack(spacing: 6) {
                        if let isIDC = info.isIDC {
                            propertyBadge(isIDC ? "IDC" : "非 IDC", color: isIDC ? .orange : .green)
                        }
                        if let isNative = info.isNative {
                            propertyBadge(isNative ? "原生" : "非原生", color: isNative ? .green : .orange)
                        }
                        if let orgType = info.orgType, !orgType.isEmpty {
                            propertyBadge(orgType.uppercased(), color: .secondary)
                        }
                    }
                }
            } else if let error = monitor.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.yellow)
                        .lineLimit(2)
                }
            } else {
                Text("正在检测当前公网出口...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.indigo.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.indigo.opacity(0.1), lineWidth: 0.5))
    }

    private func riskBadge(_ info: EgressIPInfo) -> some View {
        Text(info.riskLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(riskColor(info))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(riskColor(info).opacity(0.12)))
    }

    private func propertyBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.10)))
    }

    private func riskColor(_ info: EgressIPInfo) -> Color {
        guard let risk = info.ipRisk else {
            return .secondary
        }
        if risk <= 25 { return .green }
        if risk <= 50 { return .orange }
        return .red
    }
}
