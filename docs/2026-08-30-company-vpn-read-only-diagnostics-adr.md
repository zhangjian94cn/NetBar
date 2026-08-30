# ADR: 公司 VPN 只读诊断委托

- 日期: 2026-08-30
- 状态: accepted
- 范围: NetBar Direct Full / 公司 VPN 诊断展示
- 相关源码: [CompanyVPNDiagnosticMonitor.swift](../Sources/NetBar/Monitors/CompanyVPNDiagnosticMonitor.swift)、[MenuPopoverView.swift](../Sources/NetBar/Views/MenuPopoverView.swift)
- 相关决策: [underlay/overlay 控制边界](2026-08-28-underlay-overlay-control-boundary-adr.md)、[旧 Mini DNS 定点清理](2026-08-30-company-vpn-diagnostics-and-targeted-dns-cleanup-adr.md)

## Context and Problem Statement

OAVPN 公网入口、aTrust 企业路由和 Clash 共存基线需要在 NetBar 中可见，但这些
配置及其判定规则已经由 `dual-vpn-config` 拥有。若 NetBar 再实现一份 DNS、TLS、
hosts 或 VPN 修复逻辑，将形成第二个配置所有者，并可能让单应用故障污染物理出口状态机。

## Decision Drivers

- NetBar 可以展示公司 VPN 分层事实，但不能写 aTrust、OAVPN、hosts、Clash DNS 或 VPN 路由。
- 腾讯云对比不能把 SSH 凭据或远端执行能力带进 NetBar。
- OAVPN 或 ZCode 单端点失败不能驱动 Mac mini/Wi-Fi 切换。
- App Store Lite 不实例化该诊断入口。

## Considered Options

- NetBar 独立实现 OAVPN DNS/TLS 与腾讯云对比。
- NetBar 只显示 aTrust 进程是否存在。
- `dual-vpn-config` 生成脱敏 artifact，NetBar 只读消费并提供显式刷新按钮。

## Decision Outcome

采用第三种方案。`CompanyVPNDiagnosticMonitor` 读取所有者产生的 OAVPN endpoint
artifact 与共存基线 artifact，并补充本机 aTrust 进程和受保护路由只读事实。显式按钮
仅调用本机 `dual-vpn-config diagnose-oavpn-endpoint`，不传远端主机、不 SSH 腾讯云，
也不执行 apply、restore 或 reload。

公司 VPN 卡片只属于监控页面。它不会向 `NetworkPolicyMachine` 发送切换事件；Mini
公司 VPN 对下游的影响仍由既有 MacBook 端到端出口证据判断。

## Consequences

- 正面：用户能在 NetBar 区分客户端、企业路由、OAVPN 入口与共存基线故障。
- 正面：公司 VPN 仍只有 `dual-vpn-config` 一个逻辑所有者。
- 代价：artifact 缺失或过期时只能显示待检测，NetBar 不自行猜测。
- 风险边界：监控状态不能触发 VPN/TUN、DNS、hosts 或物理路由写入。
