# ADR: NetBar 弹窗沿用原生轻量视觉语言

- 日期: 2026-08-28
- 状态: accepted
- 范围: NetBar 菜单栏弹窗视觉语言
- 相关源码: [PopoverVisualStyle.swift](../Sources/NetBar/Views/PopoverVisualStyle.swift)、[MenuPopoverView.swift](../Sources/NetBar/Views/MenuPopoverView.swift)、[NetworkModeCard.swift](../Sources/NetBar/Views/Components/NetworkModeCard.swift)

## Context and Problem Statement

NetBar 已经通过四个顶层 Tab 解决了长页面的信息架构问题。随后尝试的“精密网络仪表”方向引入了统一青绿色、大量浮层卡、圆形图标底座和链路轨道；这些元素虽然规整，却削弱了原界面中自然的 macOS 材质、业务色彩和紧凑感。

本次需要在保留固定高度与四栏职责的前提下，恢复用户已经认可的旧版视觉气质，并确保后续页面不会再次演化成通用仪表盘模板。

## Decision Drivers

- 保留 macOS 菜单栏工具应有的轻量、原生和高信息密度。
- 出口、Clash、应用、公网 IP 和 VPS 使用可辨认但克制的业务色。
- 健康、等待和故障颜色必须保持语义一致。
- 四页共用尺寸、间距和文字层级，但不强迫所有业务卡拥有相同外观。
- UI 改造不得改变网络状态机、Helper、故障转移或 Clash/TUN 行为。

## Considered Options

1. 继续完善统一青绿色的精密仪表方向。
2. 完全恢复旧长页面，包括其嵌套导航和无限高度。
3. 保留四栏信息架构，恢复旧版原生视觉语言并精简组件规范。

## Decision Outcome

采用方案 3。弹窗继续使用 [四栏信息架构 ADR](2026-08-28-popover-information-architecture-adr.md) 定义的固定外框和底部导航，但视觉上恢复原生浅灰材质、柔和状态带、绿色策略按钮、橙色 Clash、淡紫公网 IP 和淡蓝 VPS。

共享样式只由 `PopoverVisualStyle` 提供间距、圆角、字体和语义色。出口页的两列证据网格是本界面的结构签名：它直接编码“链路、共享、端到端验证、当前出口”四项事实，而不是装饰性的流程图。

## Consequences

- 正面：保留用户熟悉的界面气质，同时通过四栏避免页面继续纵向膨胀。
- 正面：业务色重新承担识别作用，正常信息不再被过度卡片化。
- 正面：浅色与深色模式共享语义，不需要维护两套布局。
- 代价：各业务卡可以拥有不同色调，视觉 QA 必须防止颜色数量失控。
- 代价：固定高度要求应用表和诊断列表正确使用各自的滚动区域。
- 后续：新增组件应优先复用原生控件；只有属于现有业务语义时才能增加新的强调色。
