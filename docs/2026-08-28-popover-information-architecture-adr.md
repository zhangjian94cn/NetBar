# ADR: 菜单弹窗采用固定高度与底部四 Tab 信息架构

- 日期: 2026-08-28
- 状态: accepted
- 范围: NetBar 菜单栏弹窗信息架构
- 相关源码: [MenuPopoverView.swift](../Sources/NetBar/Views/MenuPopoverView.swift)、[StatusBarController.swift](../Sources/NetBar/App/StatusBarController.swift)、[PopoverPresentation.swift](../Sources/NetBar/App/PopoverPresentation.swift)

## Context and Problem Statement

NetBar 的弹窗曾把物理出口、Clash 模式、公网 IP、总速率、应用流量和 VPS 流量纵向堆叠。根视图又使用内容固有高度，`StatusBarController` 会继续按新增内容扩高；在网络诊断逐步丰富后，面板接近整屏高度，用户无法快速判断自己正在控制哪个领域。

出口与 Clash 已经由独立控制器拥有，但旧界面仍把它们放在一组内层 Tab 中，再与应用流量的实时/累计 Tab 混在同一长页面。视觉层的嵌套导航削弱了 underlay/overlay 边界，也让任何新诊断继续增加首屏长度。

## Decision Drivers

- 打开弹窗后能立即看到在线状态、已验证物理出口、Clash 模式和 DNS。
- 物理出口、Clash、应用流量和网络监控具有清晰且唯一的产品入口。
- 切换功能时面板尺寸和位置稳定，不因内容量跳动。
- 不因 UI 重构改变网络状态机、Helper、自动回退或 Clash 模式事务。
- Direct Full 与 App Store Lite 共用一个外壳，但 Lite 不暴露受限能力。

## Considered Options

1. 保留长页面，只继续折叠更多内容。
2. 使用顶部四 Tab。
3. 使用底部四 Tab，并由顶部固定状态条承担概览。
4. 增加第五个“概览”Tab，再分别提供出口、Clash、应用和监控。

## Decision Outcome

采用方案 3。Direct Full 使用 `出口 / Clash / 应用 / 监控` 四个顶层 Tab；顶部固定状态条已经承担概览，因此不增加第五个页面。页面使用 380 × 540pt 的稳定外框，内容在各自视口内滚动，产品级导航只保留一层。

`PopoverStatusPresentation` 是顶部状态文案和告警归属的唯一展示逻辑所有者。出口页继续消费 [NetworkModeController.swift](../Sources/NetBar/Monitors/NetworkModeController.swift)，Clash 页继续消费 [ClashOverlayModeController.swift](../Sources/NetBar/Monitors/ClashOverlayModeController.swift)，Tab 选择不启停或重建这些控制器。

## Consequences

- 正面：常用状态始终可见，四个任务域互不挤占首屏，新增诊断不会继续撑高整个弹窗。
- 正面：underlay 与 overlay 在产品入口上与代码所有权保持一致。
- 正面：App Store Lite 可退化为单一监控页并隐藏无意义的单项 Tab Bar。
- 代价：用户查看跨域详情需要切换页面；告警圆点和顶部状态必须保持一致。
- 代价：面板不再靠固有高度适配内容，各页面必须正确实现内部滚动和长文案截断。
- 后续：任何新增功能必须先归属到现有四个领域；只有出现新的独立用户任务，才重新评估顶层导航。
