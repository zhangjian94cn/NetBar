# 四 Tab 体验验收

- 日期：2026-10-23（本机时区）
- 范围：出口、Clash、应用、监控四页及独立设置窗口；保留原页面归属、340×460pt Direct / 340×390pt Lite。
- 正式要求：[Spec 006](https://github.com/zhangjian94cn/zhangjian-skills/blob/feature/netbar-product-experience/skills/my/infra/local-dev-config/netbar-app-management/specs/006-product-experience/spec.md)。
- 源码：[面板](../Sources/NetBar/Views/MenuPopoverView.swift)、[展示状态](../Sources/NetBar/App/ExperiencePresentation.swift)、[设置草稿](../Sources/NetBar/App/SettingsDraft.swift)、[VPS 新鲜度](../Sources/NetBar/Monitors/VPSTrafficMonitor.swift)。

## 方向和版本

用户明确要求保留四 Tab。单页总览及侧栏详情方案已取消，其代码只存在于隔离预览，未替换日常 App。四 Tab 主检查点为 `7295f54`；随后修正 Lite 常驻等待文案、未知筛选标签、减少动态效果，以及 DEBUG 预览的非交互钥匙串读取。

最终 Sources + Tests 指纹：`19eae90acd721eeaa86632f6828452b76b90ebc6401345a08d110345dee04fbb`。指纹对排序后的相对路径、NUL、文件内容、NUL 计算 SHA-256。包的本地 ad-hoc 签名通过校验，不代表 Developer ID 或 Apple 公证。

## 离线与原生旅程

最终源码 Direct Full 327 项、App Store Lite 303 项测试通过；两个 Release 包及 DEBUG Direct 预览构建通过。测试包含检测过期/网络身份变化、设置草稿 CAS、VPS 首错/过期/缺失配额、异步旧配置结果丢弃、进程采样与后台退避。

| 用户旅程 | 当前证据与结论 |
|---|---|
| 原入口与四页切换 | 四 Tab 和独立设置保留，页内滚动、齿轮、⌘,、⌘W 正常；预览实机通过 |
| 物理事实与 Clash 检测 | 物理证据与检测分别显示；原生显式 DNS/HTTPS 检测通过，仅代表两项；兼容性信息可展开 |
| 应用查找 | ⌘F、空搜索、实时/累计、时间范围、路由筛选通过；路由列注明近期证据，未知项为待确认 |
| 设置草稿 | 无效 URL 测试失败保留输入；继续编辑/放弃/保存后重开读回通过；仅在隔离偏好测试 |
| VPS | 本机演示端点 HTTP 503 首错不填零；真实返回零且无配额时显示 0 B / 额度未知；再次失败保留最近成功值并标过期；命名删除确认可取消 |
| 视觉 | 浅色/深色四页、长应用/节点名、数值列、空态及错误换行通过；Lite 原常驻等待缺陷修复后原生通过 |

上述主体旅程在四 Tab 检查点及随后的 Lite 修复版本完成，私有 AX 文本/截图记录对应加载包。最后 DEBUG 钥匙串修复还需原生复验；锁屏造成的工具不可用不算产品失败。

## 首次失败及修复

- Lite 未运行物理控制器却常驻“正在读取网络”：改为 Lite 标识，只显示已有本机地址；原生复验通过。
- 四 Tab 交互验收误用了固定截图 Tab 参数：移除强制参数后正常；参数仅用于静态截图。
- 重建预览读取旧演示钥匙串授权时窗口等待：进程采样定位 `SecItemCopyMatching`；DEBUG 预览查询使用非交互读取，正式凭据行为不变。保留首次超时及采样证据。
- 未签名发布包只有链接器签名，直接 bundle 校验不通过：本地安装候选补 ad-hoc 封装后 `codesign --verify --deep --strict` 通过；不降低公开发布签名要求。

## 资源与边界

同机历史已安装基线关闭窗口 60.058 秒平均 CPU 1.215%；四 Tab DEBUG 候选关闭窗口 60.046 秒平均 CPU 0.466%，峰值 RSS 244.42 MiB。当前应用页可见 30.044 秒平均 CPU 1.697%，峰值 RSS 185.66 MiB。测试仅说明主进程占用，子进程为采样下界，不等于温度或整机功耗。

设置窗口 30 秒样本为“尚未取得数据”状态，不能冒充连续 HTTP 503 工作负载测试。正式安装后的 60 秒窗口关闭测量另列。

已核对原任务受保护的七份 Clash 文件哈希未变，逐服务 DNS、系统代理与 IPv6 读取成功。窗口和设置验收不执行出口切换，不修改 Clash、DNS、VPN 或 Helper；网络业务与 UDP/IPv6 的既有待验结论保持独立。

## 安装与交付

待最后原生复验后一次安装；安装 receipt、恢复映射和原始证据保存在仓外私有状态目录 `netbar-product-experience`，不提交实际 IP、完整节点、配置和凭据。文档只保存脱敏结论。

PR 依赖旧 Clash 只读工作，保持 Draft。仓库工作流仅触发默认分支 PR；堆叠 PR 未执行远端 CI 时记录“未运行”，不能用本地测试代替。双屏、增强对比度尚无当前证据，保持未验证，不扩大本轮结论。
