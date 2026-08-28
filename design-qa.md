# NetBar Popover Design QA

- Date: 2026-08-28
- Scope: Direct Full fixed-height four-tab popover
- Reference: [Selected visual option 3](/Users/zjah/.codex/generated_images/01a032ac-5a0e-7f83-9162-339d52f927fa/exec-79f81952-b0f0-4b12-b928-c3007cdb8111.png)
- Implementation: [MenuPopoverView.swift](Sources/NetBar/Views/MenuPopoverView.swift), [NetworkModeCard.swift](Sources/NetBar/Views/Components/NetworkModeCard.swift), [NetworkControlTabs.swift](Sources/NetBar/Views/Components/NetworkControlTabs.swift)
- Captured implementation: [popover-tabs.png](screenshots/popover-tabs.png)

## Comparison method

The selected reference and the native SwiftUI implementation were rendered at the same `380 × 540pt` viewport and placed side by side. The four implementation tabs were then captured from the same running Debug build and reviewed together to verify that the outer frame does not move between tabs.

The reference uses a healthy sample network state, while the implementation capture intentionally preserves the machine's live degraded state. Status text and color therefore differ where the underlying facts differ; structure, hierarchy, spacing and navigation are the comparison target.

## Findings

| Priority | Check | Result |
|---|---|---|
| P0 | All four top-level tabs are reachable and render inside one fixed frame | Passed |
| P0 | Outlet and Clash controls remain operable and are not duplicated as nested product-level tabs | Passed |
| P0 | App Store Lite has no restricted control surface | Passed by build and unit coverage |
| P1 | Header, global status strip, content viewport and bottom tab bar remain in a stable hierarchy | Passed |
| P1 | Outlet page keeps critical repair actions visible while candidates and advanced diagnostics remain collapsible | Passed |
| P1 | Application table and monitoring content own their scrolling viewport without changing panel height | Passed |
| P1 | Degraded/empty states are legible and do not overflow at 380pt width | Passed |
| P2 | SF Symbols, native material, status colors, dividers and selected-tab treatment match the chosen direction | Passed |
| P2 | Chinese labels, compact numeric data and warning dots remain aligned across all tabs | Passed |

## Resolved issues

- Removed the previous long single-page stack and product-level nested tab navigation.
- Replaced content-fitting panel height with Direct Full `380 × 540pt` and App Store Lite `380 × 460pt` frames, capped by the available screen height.
- Moved Settings and Quit into the native gear menu to reclaim vertical space.
- Kept one global status summary above all pages so no fifth overview tab is required.
- Added a Debug-only deterministic capture path for repeatable visual regression checks; Release and App Store builds do not include it.

## Final result

`passed`
