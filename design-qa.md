# NetBar Popover Visual QA

- Date: 2026-08-29
- Scope: Direct Full fixed-height four-tab popover, unified design system and demoted status shell
- Reference: the rejected 2026-08-28 build (permanent status band, two-state fact colors, hardcoded spacing)
- Decision: [2026-08-29 弹窗设计系统 ADR](docs/2026-08-29-popover-shell-visual-system-adr.md)
- Implementation: [PopoverVisualStyle.swift](Sources/NetBar/Views/PopoverVisualStyle.swift), [PopoverKit.swift](Sources/NetBar/Views/Components/PopoverKit.swift), [MenuPopoverView.swift](Sources/NetBar/Views/MenuPopoverView.swift), [PopoverPresentation.swift](Sources/NetBar/App/PopoverPresentation.swift)
- Captured implementation: [light](screenshots/popover-tabs.png), [dark](screenshots/popover-tabs-dark.png)

## Comparison method

The four tabs were captured from one Debug build at `380 × 540pt` in both Aqua and Dark Aqua, via the Debug-only capture hook in [StatusBarController.swift](Sources/NetBar/App/StatusBarController.swift). Captures preserve the machine's live network facts.

Two changes make the harness safe to run next to the installed app:

- The capture run no longer starts policy monitoring ([MonitorCoordinator.swift](Sources/NetBar/App/MonitorCoordinator.swift)), so two policy owners cannot compete for real route transactions.
- The single-instance guard now keys on the running bundle identifier ([NetBarApp.swift](Sources/NetBar/App/NetBarApp.swift)) instead of the hardcoded shipping one, so a Debug capture bundle can run while the user's menu bar app stays up. Previously every capture exited silently.

`NETBAR_CAPTURE_DELAY` tunes how long the harness waits before snapshotting, because `networksetup` / `route` sampling can take several seconds to settle.

## Fixed in this pass

| Priority | Defect in the previous build | Resolution |
|---|---|---|
| P0 | Unsampled facts rendered as orange warnings (`healthy ? green : orange`), so a freshly opened panel was a wall of problems | `PopoverFactState`四态；`unknown` 为空心灰环加次要色文字 |
| P0 | Badges on three of four tabs at all times, carrying no information | `needsAttention` 改由可处理信号驱动；`.switching`、`routeEligible`、`preflightEligible`、`degradedActive` 与未采样不再触发 |
| P0 | Permanent pink alarm band occupying three lines at the top of every tab | 状态并入 header 单行；`primaryReason` 改由拥有该问题的页面以 banner 呈现 |
| P1 | Tab bar inset 12 against content inset 16, a visible 4pt misalignment | 唯一 `contentInset = 16`，导航与内容共用 |
| P1 | Selected pill only 0.04 alpha above its own container | 选中态改用 accent 色相；Graphite 系统强调色回退到 `systemBlue` |
| P1 | Card surfaces invisible in Dark Aqua over `.regularMaterial` | 表面改用 `NSColor(name:dynamicProvider:)`，浅深各自调 alpha |
| P1 | Applications tab left dead space below a hard-coded 150pt table body | 表体改 `maxHeight: .infinity`，填满固定外框 |
| P2 | 10pt primary tier below `NSFont.smallSystemFontSize`; spacing 13/11/9/7/6/4/3; radii 5/6/9/10/11/12/18 | 字号最小档提到 11pt；间距 4/8/12/16；圆角 6/10/10/16 |
| P2 | Seven hues with green meaning both "healthy" and "press me" | 状态色仅用于点与横幅；选中与操作用 accent；业务色降级为卡片前导图标 |
| P2 | `—` placeholders dominating the outlet evidence grid | 空占位不渲染；`addressText` 只拼接已知的一半 |

## Structural results

- Removed 5 fact-row implementations, 2 disclosure implementations, 2 segmented-control treatments, 4 badge implementations, 3 banner implementations, and 2 pure pass-through row files.
- Outlet display logic moved from the view into `NetworkOutletPresentation`, now covered by `PopoverPresentationTests`.
- `swift test`: 223 tests, 0 failures. Network state machine, Helper, failover and Clash/TUN sources unchanged.

## Verified in the captures

| Check | Result |
|---|---|
| All four tabs render inside one `380 × 540pt` frame in both appearances | Passed |
| Tab bar and page content share the same left/right edge | Passed |
| Exactly one accent-filled element per page (the current selection) | Passed |
| Unknown facts render as hollow rings, not warnings | Passed |
| Tab badges appear only for the two genuinely faulted domains (offline outlet, Clash coexistence baseline) | Passed |
| Card surfaces legible in both Aqua and Dark Aqua | Passed |
| Applications table fills the frame and truncates long app names without overflow | Passed |
| Outlet, Clash and monitoring pages keep their own scrolling viewport | Passed |
| No content overflows the fixed frame at the larger type scale | Passed |

## Known, not addressed here

- The outlet grid can pair `端到端验证 / 不可用` with the detail `Mac mini 正常`, because the proof level and `NetworkFailoverPhase` disagree. That is controller state, not presentation, and is left untouched by this pass.
- `SettingsView` has not been migrated onto the token scale.
- `L10n` still covers only part of the user-visible strings.

## Final result

`passed`
