# ADR: 弹窗改用统一设计系统与降级状态外壳

- 日期: 2026-08-29
- 状态: accepted
- 范围: NetBar 菜单栏弹窗视觉系统与视图层结构
- 相关源码: [PopoverVisualStyle.swift](../Sources/NetBar/Views/PopoverVisualStyle.swift)、[PopoverKit.swift](../Sources/NetBar/Views/Components/PopoverKit.swift)、[MenuPopoverView.swift](../Sources/NetBar/Views/MenuPopoverView.swift)、[PopoverPresentation.swift](../Sources/NetBar/App/PopoverPresentation.swift)
- 取代: [2026-08-28 弹窗沿用原生轻量视觉语言](2026-08-28-popover-visual-language-adr.md)（部分决定）
- 保留: [2026-08-28 固定高度与底部四 Tab 信息架构](2026-08-28-popover-information-architecture-adr.md)（全部）

## Context and Problem Statement

四栏信息架构与"恢复原生视觉语言"两轮改造后，`design-qa.md` 判定 `passed`，但界面观感仍然差。复查截图与源码后，问题不是配色审美，而是三件可量化的事：

1. **语义层把"未知"画成了"警告"。** `healthy ? green : orange` 这个二态判断遍布证据网格、诊断行和 Tab 徽章，任何"尚未采样"的事实都渲染成橙色告警。刚打开的面板因此是一整屏问题。
2. **没有真正的设计系统。** 间距散落在 13/11/9/7/6/4/3，圆角散落在 5/6/9/10/11/12/18，主力字号 10pt 低于 macOS `NSFont.smallSystemFontSize`。内容区 inset 16 而 Tab 栏 inset 12，错位肉眼可见；选中态 `0.11` 叠在容器 `0.07` 上只有 0.04 alpha 差。
3. **顶部状态条常驻告警。** `statusStrip` 无条件渲染 `statusFill(for: tone)`，`.negative` 时是整块粉底，占三行，且与 Clash 页、监控页的内容重复。

同时视图层存在大量重复：同一个"标签+值"写了 5 遍，折叠行 2 遍，分段控件 2 套互不一致的选中样式，彩色胶囊 4 套，告警条 3 套。出口页还在视图内自行计算展示文案，违反了信息架构 ADR "`PopoverStatusPresentation` 是唯一展示逻辑所有者"的约定。

## Decision Drivers

- 未采样、进行中和真实故障必须视觉可分；徽章只标记用户能动手处理的事。
- 一套间距 / 圆角 / 字号尺度，所有页面共用，包含导航。
- 浅色与深色共享语义，且深色下卡片面必须可见。
- 业务色仍要承担识别作用，但不能再决定整块表面的颜色。
- 不改网络状态机、Helper、故障转移与 Clash/TUN 行为。

## Considered Options

1. 只调颜色和间距，保留现有二态语义与顶部状态条。
2. 建立 token + 组件体系，降级顶部状态条，重划语义与强调色职责。
3. 推翻四栏信息架构重做导航。

## Decision Outcome

采用方案 2。信息架构 ADR 的四栏、固定外框与单层产品导航全部保留；被修订的是视觉语言 ADR 中关于状态条、卡片着色与强调色的部分决定。

**事实四态。** `PopoverFactState` 取代布尔健康判断：`ok` 实心绿、`warning` 实心橙、`fault` 实心红、`unknown` 空心灰环加次要色文字。`PopoverFactState(ready:)` 明确把 `nil` 映射为 `unknown`。占位 `—` 不再渲染，`NetworkOutletPresentation.addressText` 只拼接已知的那一半。

**徽章只标记可处理的事。** `needsAttention` 从"未达 `activeVerified`"改为 `outletFault || proofLevel == .unavailable`；Clash 从 `health != .ready` 改为排除 `.switching`；监控从"DNS 未就绪"改为 `dependency ∈ {miniDependent, unreachable}`。`routeEligible`、`preflightEligible`、`degradedActive` 和"尚未采样"都不再触发徽章。

**状态条降级并入 header。** 去掉 globe 与 "NetBar" 字样，header 一行承载状态点、连通状态与当前出口。`primaryReason` 改由拥有该问题的页面以 `PopoverBanner` 呈现，而不是常驻顶条。

**强调色与状态色分职。** `healthy/warning/fault` 只用于状态点与横幅；选中态与操作使用 `PopoverVisualStyle.accent`。该 accent 跟随系统强调色，但系统设为 Graphite 时回退到 `systemBlue`——灰色强调色会让选中态失去色相差异，正是本次要消除的问题。业务色（公网 IP 淡紫、VPS 淡蓝）降级为卡片前导图标着色，不再填充整块卡面。整页只有当前选中项使用强调色填充，`PopoverActionButton` 落在中性面上，避免修复按钮与主控件同权重。

**一套尺度。** 间距 4/8/12/16 与唯一 `contentInset = 16`（Tab 栏同用）；圆角 6/10/10/16；字号最小档提到 11pt。表面色改用 `NSColor(name:dynamicProvider:)`，浅色深色各自调 alpha。

**共享组件。** `PopoverKit.swift` 提供 `PopoverFactTile`、`PopoverFactRow`、`PopoverCard`、`PopoverDisclosure`、`PopoverSegmentedOption`、`PopoverBadge`、`PopoverBanner`、`PopoverActionButton`。出口页的展示逻辑移入 `NetworkOutletPresentation`，与 `PopoverStatusPresentation` 并列，可单测。

## Consequences

- 正面：未采样不再冒充故障，健康路径下 Tab 徽章归零，面板不再常驻告警。
- 正面：视图层删除 5 套事实行、2 套折叠行、2 套分段控件、4 套徽章、3 套告警条与 2 个纯转发文件。
- 正面：出口页展示逻辑进入 presentation 层后可被 `PopoverPresentationTests` 覆盖。
- 正面：深色模式卡片面由动态色提供，不再消失在 `.regularMaterial` 上。
- 代价：本 ADR 修订了 2026-08-28 视觉语言 ADR 中"绿色策略按钮、橙色 Clash、淡紫公网 IP 卡、淡蓝 VPS 卡"的着色方式；业务色保留但只作用于图标。
- 代价：accent 需要感知 Graphite 回退，这是一处平台相关分支。
- 后续：`SettingsView` 尚未迁移到本 token 体系；`L10n` 仍只覆盖部分文案。
