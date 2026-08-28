# NetBar Popover Visual QA

- Date: 2026-08-28
- Scope: Direct Full fixed-height four-tab popover, restored native visual language
- Reference: the accepted pre-tab NetBar popover visual language
- Implementation: [PopoverVisualStyle.swift](Sources/NetBar/Views/PopoverVisualStyle.swift), [MenuPopoverView.swift](Sources/NetBar/Views/MenuPopoverView.swift), [NetworkModeCard.swift](Sources/NetBar/Views/Components/NetworkModeCard.swift)
- Captured implementation: [light](screenshots/popover-tabs.png), [dark](screenshots/popover-tabs-dark.png)

## Comparison method

The four tabs were captured from one Debug build at `380 × 540pt` in both Aqua and Dark Aqua. Captures preserve the machine's live network facts, so the review validates hierarchy, spacing, semantic color, truncation and fixed-frame behavior rather than forcing a synthetic healthy status.

## Findings

| Priority | Check | Result |
|---|---|---|
| P0 | All four top-level tabs are reachable and render inside one fixed frame | Passed |
| P0 | Outlet and Clash controls remain operable and are not duplicated as nested product-level tabs | Passed |
| P0 | App Store Lite has no restricted control surface | Passed by build and unit coverage |
| P1 | Header, soft global status band, content viewport and bottom tab bar remain in a stable hierarchy | Passed |
| P1 | Outlet page uses a readable two-column evidence grid and keeps critical repair actions visible | Passed |
| P1 | Application table and monitoring content own their scrolling viewport without changing panel height | Passed |
| P1 | Degraded/empty states are legible and do not overflow at 380pt width | Passed |
| P2 | SF Symbols, native material, semantic business colors and selected-tab treatment match the restored direction | Passed |
| P2 | Chinese labels, compact numeric data and warning dots remain aligned across all tabs | Passed |
| P2 | Aqua and Dark Aqua preserve the same status meanings without neon or low-contrast text | Passed |

## Resolved issues

- Removed the rejected dashboard-style signal rail, round icon backplates and universal teal palette.
- Restored the original soft status band, green route controls, orange Clash controls, lavender public-IP card and cyan VPS card.
- Kept the fixed Direct Full `380 × 540pt` and App Store Lite `380 × 460pt` frames from the accepted information architecture.
- Added an appearance selector to the existing Debug-only capture path; Release and App Store builds do not include it.

## Final result

`passed`
