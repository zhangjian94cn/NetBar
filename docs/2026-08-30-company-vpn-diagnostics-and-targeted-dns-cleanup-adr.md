# ADR: 旧 Mini DNS 定点清理

- 日期: 2026-08-30
- 状态: accepted
- 范围: NetBar Direct Full / Route Safety Helper v5
- 相关源码: [NetworkConnectivity.swift](../Sources/NetBar/Monitors/NetworkConnectivity.swift)、[Route Safety Helper](../Sources/NetBar/Resources/RouteSafetyHelper/netbar-route-safety-helper)
- 相关决策: [端到端 DNS ADR](2026-08-28-end-to-end-dns-overlay-failover-adr.md)、[overlay 委托 ADR](2026-08-28-underlay-overlay-control-boundary-adr.md)

## Context and Problem Statement

Wi-Fi 同时配置 `223.5.5.5`、`119.29.29.29` 和旧 Mini 地址 `192.168.2.1` 时，
系统解析实际可用，但旧模型只要看到 Mini 地址就把整条 DNS 路径判为依赖 Mini。
原修复按钮又会把全部手动 DNS 清空，超出了用户“只清理旧地址”的意图。

## Decision Drivers

- 普通出口切换不能写 DNS，也不能自动改变 TUN/VPN。
- 用户选择的公共 DNS 必须在清理旧 Mini 地址后原样保留。
- App Store Lite 继续不提供特权写入或公司 VPN 控制入口。

## Considered Options

- 继续把任意包含 `192.168.2.1` 的列表判为完全依赖 Mini。
- 点击后统一恢复 DHCP 自动 DNS。
- 分开“旧地址存在”和“有效 DNS 是否可用”，并提供定点清理事务。

## Decision Outcome

采用第三种方案。`DNSPathFacts` 新增 `hasLegacyMiniResolver` 和
`effectiveDNSReady`；健康公共 resolver 在前时依赖仍为 independent，但监控页显示可操作
告警。Route Safety Helper v5 增加唯一固定命令 `remove-legacy-mini-dns`，只删除精确旧
地址，沿用 root-only 备份、SHA-256、commit/rollback 和启动恢复契约。

## Consequences

- 正面：公司和外部 Wi-Fi 均可保持独立 DNS，清理旧地址不会丢失 223/119。
- 代价：升级 Route Helper 需要一次管理员授权；之后普通操作继续免授权。
- 风险边界：应用端点状态不参与物理路由 reducer；Mini 下游失败仍由既有端到端证据决定。
