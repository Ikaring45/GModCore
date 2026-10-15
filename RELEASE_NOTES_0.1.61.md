# Garry's PAD / GModCore 0.1.61

## Japanese VGUI input and rendering

- Native Japanese IME composition for original MENU and CLIENT Q/C TextEntry
  panels. Candidate edits stay in UIKit until committed, with focus-safe queued
  insertion, Backspace and Return routed to the original Lua callbacks.
- Shared CoreText shaping for measurement and rasterization, stable mixed
  Japanese/Latin font scaling and caret placement, and correct original OnEnter
  text arguments.
- Bounded, font-aware measurement caching reduces repeated text layout work
  without retaining stale measurements after a font definition changes.

## Session stability

- Embedded normal walking rejects the movement but keeps the session and
  CLIENT/SERVER FIFO alive, so noclip or teleport can recover the player.
- Retains persistent stock Q presentation, touch window drag/resize and Hint
  overlay lifecycle behavior. Permission denial and non-finite state checks
  remain authoritative.

## Validation boundary

- Windows: 65 related VGUI/localization/Hint/MENU/session tests passed; the 3
  affected MENU/session tests passed again after the final OnEnter adjustment.
- [Linux CI](https://github.com/Ikaring45/GModCore/actions/runs/38727207225):
  45 portable tests passed.
- [Apple CI](https://github.com/Ikaring45/GModCore/actions/runs/38726635529),
  production source `a238a3b`: strict ARM64 libraries, installable iPad app,
  Metal pipeline smoke, Simulator launch and accessibility smoke passed.
  The dedicated Japanese VGUI/IME/stock Q/noclip regression gate also passed.
  Release changes after that production source are CI/docs/version metadata.
- The full Apple XCTest suite is separate and is not reported as passed.
  Physical iPad/Swift Playgrounds presentation and IME candidate UI remain
  unverified. This release does not claim complete Source/VGUI compatibility.

For Swift Playgrounds, select package version **0.1.61** from the existing
GModCore GitHub package source.
