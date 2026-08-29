# NetBar Popover Visual QA

- Date: 2026-08-29
- Scope: Direct Full four-tab popover — compact geometry, dense type scale, two-role palette, data meters
- Reference: the 2026-08-29 first pass (380 × 540pt, 11–20pt type, purple/cyan card icons)
- Decision: [2026-08-29 弹窗设计系统 ADR](docs/2026-08-29-popover-shell-visual-system-adr.md)
- Implementation: [PopoverVisualStyle.swift](Sources/NetBar/Views/PopoverVisualStyle.swift), [PopoverKit.swift](Sources/NetBar/Views/Components/PopoverKit.swift), [MenuPopoverView.swift](Sources/NetBar/Views/MenuPopoverView.swift)
- Captured implementation: [light](screenshots/popover-tabs.png), [dark](screenshots/popover-tabs-dark.png)

## Comparison method

Four tabs captured from one Debug build in both Aqua and Dark Aqua via the Debug-only hook in [StatusBarController.swift](Sources/NetBar/App/StatusBarController.swift), rendered from the machine's live network facts. Captures measured 680 × 920px at 2x, confirming the 340 × 460pt frame.

The capture bundle uses its own bundle identifier and does not start policy monitoring, so it neither touches the installed app's preferences nor competes with it for route transactions. `NETBAR_CAPTURE_DELAY` was set to 12s so the sparkline window had enough samples to render.

## Fixed in this pass

| Priority | Defect | Resolution |
|---|---|---|
| P0 | Panel too large at 380 × 540pt | 340 × 460（Lite 340 × 390），几何收进 `PopoverVisualStyle.Metrics` |
| P0 | Type scale too large (11–20pt) | 整体下移一档 → 10 / 11 / 12 / 13 / 15 |
| P1 | Width declared twice (`StatusBarController` + `MenuPopoverView`) | 两处都从 `Metrics.panelWidth` 读 |
| P1 | IP rendered at a hardcoded 20pt mono, bypassing the type scale | 改用 `Typography.metric` |
| P1 | Row rhythm loose | fact 30→26 / 折叠 36→30 / Tab 40→34 / 表格行 30→26 / 表格图标 20→16；`contentInset` 16→12 |
| P2 | Purple and cyan card icons were the last decorative hues | 全部中性化，面板只剩状态色与强调色 |
| P2 | Quota, share and risk existed as numbers only | `PopoverMeter` 用于 VPS 配额、应用占比、IP 风险值 |
| P2 | Speed shown as two instantaneous figures with no trend | `PopoverSparkline` + `NetworkMonitor.speedHistory`（上限 60） |

## Verified in the captures

| Check | Result |
|---|---|
| Captures measure 680 × 920px at 2x, i.e. the intended 340 × 460pt | Passed |
| Applications table shows 10 full rows with the 11th clipped, signalling scroll | Passed |
| App names, `Mac mini 上游待检测` and the IP location string fit at 340pt wide | Passed |
| Share tracks readable behind rows without consuming a column | Passed |
| Sparkline reads as a trend, not as a rule pinned to the top edge | Passed |
| IP risk meter correctly absent when `ipRisk` is nil | Passed |
| Only status colors and the accent appear; no decorative hues | Passed |
| Card surfaces and meters legible in both Aqua and Dark Aqua | Passed |
| No content overflows the 460pt frame | Passed |

`swift test`: 230 tests, 0 failures. Both distribution flavors build.

## Regressions guarded by tests

`PopoverMeterTests` covers the two ways a meter can lie:

- An undefined proportion returns `nil`, so an unlimited VPS quota omits the bar instead of drawing 0%.
- A constant rate keeps every sparkline point below the ceiling, so a steady connection cannot render as a flat rule along the top edge.

## Known, not addressed here

- The VPS quota meter has no on-machine data to exercise it (no VPS configured); its behaviour is covered by unit tests only.
- The outlet grid can still pair `端到端验证 / 不可用` with the detail `Mac mini 正常`, because the proof level and `NetworkFailoverPhase` disagree. Controller state, untouched by this pass.
- `SettingsView` is not on the token scale; `L10n` still covers only part of the user-visible strings.

## Final result

`passed`
