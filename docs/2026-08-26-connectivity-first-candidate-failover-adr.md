# ADR: 连通性优先的候选池故障转移与 Mihomo 无重启收敛

- 日期: 2026-08-26
- 状态: partially superseded（控制器内联决策由 2026-08-27 ADR 分阶段取代）
- 范围: NetBar Direct Full / MacBook 物理出口候选与 Clash 数据面收敛
- 相关源码: [NetworkConnectivity.swift](../Sources/NetBar/Monitors/NetworkConnectivity.swift)、[NetworkModeController.swift](../Sources/NetBar/Monitors/NetworkModeController.swift)、[NetworkRoutePolicy.swift](../Sources/NetBar/Monitors/NetworkRoutePolicy.swift)、[MihomoClient.swift](../Sources/NetBar/Monitors/MihomoClient.swift)、[NetworkModeCard.swift](../Sources/NetBar/Views/Components/NetworkModeCard.swift)
- 部分取代: [2026-08-26-mac-mini-preferred-route-self-healing-adr.md](2026-08-26-mac-mini-preferred-route-self-healing-adr.md) 中固定 Mini/Wi-Fi 双候选、固定 10 秒检查和 VPN/TUN 完全只读的选择
- 上位原则: [engineering-principles.md](../../../docs/engineering-principles.md)
- 取代决策: [2026-08-27-evidence-driven-network-policy-machine-adr.md](2026-08-27-evidence-driven-network-policy-machine-adr.md)

## Context and Problem Statement

原有 Mini 优先策略能在 Mini Guardian 明确报告上游故障时回退，但雷雳线直接断开会被转换成网关 `unknown`，没有进入立即回退分支。即使服务顺序已经切到 Wi-Fi，旧的 Mihomo/TUN 连接也可能继续绑定失效的底层路径，形成“Wi-Fi 显示已选中，但退出 Clash 后才恢复”的假成功。

同时，本机有大量 macOS 历史 Wi-Fi 配置。自动遍历全部配置既会产生抖动，也会错误尝试不再可信、需要网页登录或不在附近的网络。需要把“物理连接存在”“直连互联网可用”“Clash 数据面收敛”和“实际物理出口”分层验证，并限定自动连接候选的权限边界。

## Decision Drivers

- 保持上网优先于等待首选 Mini；明确链路故障必须在健康 Wi-Fi 存在时快速回退。
- Mini 仍是长期首选，5 分钟只定义恢复探测频率，不得成为离线等待时间。
- Wi-Fi 自动关联不得读取、接收或保存密码，也不得遍历全部历史配置。
- 网络切换的完成条件必须同时覆盖物理出口、绑定直连 HTTPS 和现有 Clash/TUN 数据面。
- 不退出、重启、重载或改写 Clash；公司 DNS 和其他 VPN/TUN 继续属于外部配置。
- App Store Lite 不得携带候选自动连接或 Mihomo 写能力。

## Considered Options

1. 雷雳断开后等待 Mini 最多 5 分钟再回退。会造成可避免的断网，违背连通性优先。
2. 自动尝试 macOS 的全部已保存 Wi-Fi。候选过多、不可见且包含过期网络，无法形成用户可审计的信任边界。
3. 切换失败时退出或重启 Clash。恢复面过大，会中断 VPN/TUN 并掩盖底层路由是否真正修复。
4. 使用用户置顶白名单，先验证候选 Wi-Fi 再切物理优先级；仅在直连成功而 Clash 数据面失败时关闭 Mihomo 当前连接并复检。

## Decision Outcome

采用方案 4。主界面只提供“Mac mini 优先”和“Wi-Fi 优先”两个持久策略，不再暴露语义重叠的“固定 Wi-Fi”和“立即用 Wi-Fi”。候选集合为 CoreWLAN 发现的“附近可见、macOS 已保存、用户置顶”交集，并保持用户顺序。当前已连接且健康的白名单网络优先保留。CoreWLAN 扫描需要定位权限；权限被拒绝时不尝试其他 SSID。若系统同时隐藏当前 SSID 名称，但 `en0` 已经关联且具有 IPv4，则在候选池持续显示“当前已连接 Wi-Fi”，并允许把它作为不持久化的匿名候选；只调整服务顺序，不执行关联。普通关联通过参数数组调用 `/usr/sbin/networksetup -setairportnetwork en0 <SSID>`，不提供密码，也不读取钥匙串。

`SCDynamicStore` 与 CoreWLAN 事件触发即时复检，10 秒定时器仅兜底。雷雳无载波、`bridge0`/固定地址丢失或 Peer 不可达是明确故障；先关联候选并验证 `en0` 的载波、IPv4 和网关。绑定直连 HTTPS 可用时采用 make-before-break。实机验证发现公司网络会同时阻断 Wi-Fi 与雷雳接口上绕过代理的 HTTPS，但系统与 Clash/TUN 数据面可用。Wi-Fi 要求实际物理出口为 `en0`、系统 HTTPS 与 Clash HTTPS 同时成功；Mini 切换前要求固定链路、绑定 `bridge0` 的公网 ICMP 至少一个目标成功及 Guardian `ready`，切换后要求实际物理出口为 `bridge0`、系统 HTTPS 与 Clash HTTPS 同时成功，否则恢复 Wi-Fi。任何显式链路或 Guardian 故障立即回退；仅有瞬时数据面失败时继续使用既有三轮确认，避免单次抖动误判。

回退后立即使用 Wi-Fi 保网；前 5 分钟每 10 秒探测 Mini，之后每 60 秒探测。Mini 绑定出口连续健康 30 秒且 Guardian `ready` 后自动切回。短期重复失败继续使用 10 分钟熔断。

每次确认实际物理出口由 `bridge0` 切到 `en0`，或由 `en0` 切到 `bridge0`，NetBar 都通过 Mihomo Unix Socket 调用一次 `DELETE /connections`，随后等待并重新验证数据面；不能只在 Wi-Fi 直连成功但代理探测失败时才清理，因为公司网络可能禁止绕过代理直连，而且浏览器旧连接失败时新建的健康探测仍可能成功。相同物理出口的重复检查不清理连接；控制面暂不可用或清理失败时保留待处理转换，并按受控间隔重试。该 API 只关闭当前连接，使新拨号跟随新底层路由；NetBar 不调用重启、重载、TUN 开关或配置写接口。Clash 持久配置仍由 `dual-vpn-config` 独占治理。

上述 Mini 分层证明替代“绑定接口直连 HTTPS 必须成功”的旧硬门，但不允许只凭 VPN/TUN 公网可达宣称 Mini 正常：切换前的 `bridge0` 绑定 ICMP 与 Guardian、切换后的服务顺序和实际物理默认路由仍是不可省略的证据。

在 `miniPreferred` 下，若实际默认物理路由已经是 `bridge0`，但服务顺序仍把 Wi-Fi 排在雷雳前，协调器必须通过受限 Route Safety Helper 纠正为 Mini 优先并回读验证；不能因为当前数据面暂时可用就保留该不一致，否则 macOS 后续收敛会重新落到 Wi-Fi。纠正失败时保持当前可用 Mini 出口并显式告警，不主动切到 Wi-Fi。

## Consequences

- 正面：拔掉雷雳后不再等待远端网关状态；普通网络采用 make-before-break，公司网络阻断直连时以物理出口加现有代理/TUN 数据面验证可用性。
- 正面：UI 用两个优先策略、当前物理出口和折叠候选列表表达状态，减少一次性动作与长期策略混淆；5 分钟阶段和 Clash/TUN 未收敛仍按需展示。
- 正面：用户明确控制自动候选范围；定位拒绝和关联授权失败均 fail closed。
- 正面：雷雳热插拔、自动回退、自动切回及手动切换都会刷新 Mihomo underlay；Mihomo PID、TUN 开关、配置文件和其他 VPN 进程保持不变。
- 正面：公司网络禁止绕过代理直连时，Mini 不会因单一 HTTPS 假阴性被错误回退；切换后的物理路由与系统/Clash 数据面仍是硬门。
- 正面：目标策略、服务顺序和实际物理出口重新成为同一闭环，短暂“实际走 Mini、顺序仍是 Wi-Fi”的状态会被主动纠正。
- 代价：物理出口真正变化时，已有 Mihomo 连接会被关闭并自动重拨，个别长连接会发生一次可恢复的短暂中断。
- 代价：Direct Full 增加 CoreWLAN/CoreLocation 依赖，并需要一次定位许可才能发现非当前候选。
- 代价：候选 Wi-Fi 需先由 macOS 保存凭据；Captive Portal 和需要额外授权的网络不会后台完成认证。
- 限制：所有候选直连失败时只能告警；一次 Mihomo 连接清理后仍未收敛时保持 Wi-Fi 物理出口并提示打开 Clash。
- 隐私：滚动 JSONL 仅记录状态转换和动作，Wi-Fi 使用 SHA-256 短标识，不记录完整 SSID、BSSID、密码、代理密钥；保留上限为 7 天或 2 MB。

## Verification

- 候选交集、定位拒绝、排序、关联参数、Captive Portal 状态码与 5 分钟/60 秒阶段由 [NetworkConnectivityTests.swift](../Tests/NetBarTests/NetworkConnectivityTests.swift) 覆盖。
- 雷雳明确故障立即回退、公司网络阻断直连 HTTPS 时 Mini 保持/切回、三轮不确定故障、第二候选、30 秒切回、切回回滚、双向物理出口变化的 Mihomo 单次清理、同出口去重和熔断由 [NetworkRoutePolicyTests.swift](../Tests/NetBarTests/NetworkRoutePolicyTests.swift) 覆盖。
- Helper 固定命令与无 DNS/VPN 写入边界继续由 [NetworkStaticLinkTests.swift](../Tests/NetBarTests/NetworkStaticLinkTests.swift) 覆盖。
- 交付必须运行完整 `swift test`、Direct Full/App Store Lite 双构建、真实绑定 HTTPS、Helper/Guardian 状态回读，以及安装后二进制哈希和单进程检查。
