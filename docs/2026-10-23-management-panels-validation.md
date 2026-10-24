# 监控页管理面板验收

- 日期：2026-10-23（本机时区）。
- 用户故事：在原四 Tab 的监控页打开 BWG 原生与已部署服务后台，并在本机保存登录信息。
- 源码：[记录与钥匙串](../Sources/NetBar/App/ManagementPanels.swift)、[原生管理窗口](../Sources/NetBar/Views/ManagementPanelsView.swift)、[checked Keychain 操作](../Sources/NetBar/Utilities/KeychainHelper.swift)。
- 正式要求：既有 [Spec 006](https://github.com/zhangjian94cn/zhangjian-skills/blob/feature/netbar-product-experience/skills/my/infra/local-dev-config/netbar-app-management/specs/006-product-experience/spec.md) 的 US7、FR-013 至 FR-015。

## 实现与边界

保留出口、Clash、应用、监控四 Tab 及独立设置窗口。监控页首部增加管理面板卡片；管理窗口单实例，提供添加、编辑、导入、删除、保存与取消。入口和登录信息整体保存在现有系统 Keychain 服务的独立条目，不写普通偏好。默认遮罩密码，显隐和复制为显式动作；30 秒后只清理仍属于本次复制的剪贴板。读取错误不当作空库；写入比较原记录并读回，失败保留草稿和旧数据。

真实安装导入 7 个入口：BWG KiwiVM、BWG 客户中心、既有 3X-UI、搬瓦工与南京 sub2api、Forgejo、Drone。其中 3 个有现有网页登录密码；KiwiVM 只有账号，BWG 客户中心密码未找到。Forgejo/Drone 沿浏览器会话或 OAuth，不把 API Token 当作网页密码。私有来源与匹配证据保存在仓外，不提交账号、密码、完整节点或后台私人路径。

打开由默认浏览器处理，登录和 MFA 仍由浏览器完成。sub2api 固定两个 host 和回环端口，委托原服务脚本；其 SSH/watchdog 归原所有者。Lite 只打开 URL 并提示手动隧道。无新的 Clash、DNS、TUN、VPN、服务端或 Helper 写操作。

## 版本与离线结果

Sources/Tests 指纹：`837d9a5efb693ec196341e0a7c1f0e18d663223f190122785a70aa45f511dda6`。

Direct Full 339 项、正确 `APP_STORE` 编译条件下 Lite 315 项全测通过；之后仅调整 DEBUG 预览入口的旧 Keychain 非交互读取和错误文字，当前 12 项定向测试及两个 Release 包通过。新增测试覆盖 URL/隧道约束、记录轮转与删除、导入保留同 ID、损坏/锁定/CAS/写失败、剪贴板所有权和子进程存活。

首次全测暴露既有 scheduler 测试的排队标记竞态：标记可能早于真实 pending 任务完成。测试改等实际任务 expectation，并避免失败后越界；原始失败和复验均保留。曾误用 `APPSTORE_LITE` 的运行不计作 Lite 验收。

Direct/Lite 均构建成功。本地安装采用 ad-hoc 封装并通过 `codesign --verify --deep --strict`；没有 Developer ID 或 Apple 公证，不宣称公开发布门槛通过。

## 原生旅程

| 旅程 | 结果与证据范围 |
|---|---|
| 四 Tab 监控入口 | 隔离 Direct 预览与安装版均能看到管理入口；固定 Tab 参数只用于该监控页验证 |
| 导入与保存 | 演示记录导入、保存编辑、退出进程后读回通过；正式 App 经原生文件选择器导入 7 项，checked 写后读取成功 |
| 密码 | 演示显隐/复制通过；正式仅验证遮罩和凭据状态，不截图明文 |
| 错误与取消 | 非法地址保留输入；取消恢复；关闭草稿提供保存/放弃/继续编辑；继续编辑及保存通过；删除确认取消通过 |
| 隧道缺失 | 隔离预览缺失脚本时显示原因，不打开错误后台 |
| 默认浏览器 | 隔离预览点击 KiwiVM 后实际到达原生登录页，未提交登录 |
| 正式隧道与服务 | 仍需继续：首次隧道点击被 macOS Documents 文件访问授权阻塞，随后桌面锁定；不把现存隧道 `/health` 返回 200 当作该按钮通过 |

旧预览身份的 Keychain ACL 曾导致 `SecItemCopyMatching` 与 `SecItemAdd` 等待；线程采样表明 UI 主线程仍在事件循环。checked 操作临时禁用 Keychain 交互并恢复原进程标志；DEBUG 预览启动时禁用旧演示项交互。复验保存和重新启动回读通过，不修改旧 ACL。正式导入由最终安装 App 本身执行，未用外部工具建立它的 Keychain 授权。

真实隧道点击时，系统日志明确记录当前 NetBar 代码与旧 Documents 授权要求不匹配，等待文件访问确认。原生工具禁止操作系统授权弹窗；已让用户在本机决定。此项不需要 AX、管理员密码或 Helper。若拒绝，使用普通浏览器入口和原有手动隧道流程，不自动更改权限。

## 安装、恢复与待验

安装二进制 SHA-256：`21bceba758ef295c06c3784c79f3c03d991f87ebbb4eba97f7756c1896eb09cd`。安装前确认旧 App 与七份受保护 Clash 文件未发生并发变化，备份旧 App、必要偏好和 LaunchAgent；原 LaunchAgent 文件保持不变。仓外私有目录保存安装 receipt、版本、截图、首次失败和恢复映射。

回退时先停原 LaunchAgent，将私有备份中的旧 App 恢复到原安装位置后重新加载；不还原整个 Keychain、不动远端或网络 Helper。管理面板记录独立，旧 App 不读取它。偏好只有在校验仍属于本次修改时才恢复。

安装后七份受保护 Clash 文件、逐服务 DNS、系统代理与 IPv6 读回均与基线一致，正式进程一个；临时明文导入文件在 checked Keychain 写后读回成功后删除。Forgejo 与 Drone 的既有浏览器页面可读且保留现有会话，这不是 NetBar 按钮旅程的替代证据。

当前安装和凭据保存通过；全部真实链接、正式隧道、安装后重启回读与资源抽样尚待当前桌面证据。未复测内容沿既有结论，不借本轮入口功能宣称网络、业务或 VPS 健康通过。

Skills 改动的 5 份文档路径检查通过；全 Skill 目录扫描另发现 27 个旧跨仓链接在隔离 worktree 缺失，不属于本次新增链接。`manage.py verify` 按 owner 生成全量计划并执行，asset-build 通过，其余套件未过：所用系统 Python 缺 pytest、隔离验证拒绝未提交工作树，以及原浏览器报告缺失。原始日志保留，不把这些环境/门禁失败算作功能通过，也不为本轮入口改动降低全仓门禁。两个堆叠 PR 仍为 Draft，远端适用工作流未运行，不用本地绿测代替 CI。
