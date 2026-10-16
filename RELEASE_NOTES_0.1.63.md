# Garry's PAD / GModCore 0.1.63

## MENU stability and layout

- Moves MENU startup, original Derma callbacks and shutdown to a dedicated
  16 MiB-stack actor worker. Startup no longer blocks MainActor with recursive
  original Lua initialization. Final cleanup runs on the same worker.
- Reduces Q/C dependent-layout queue overhead while preserving deterministic
  panel ordering, scoped rendering, Hint updates and animations.
- Fixes FILL docking taking space underneath later-created edge controls.
  Original DNumSlider labels (including Damage/Delay), slider tracks and value
  fields now occupy separate areas without changing shipped Lua controls.

## Validation boundary

- 63 focused Windows tests passed, including the stock DNumSlider after
  Retina Q/C/Hint transitions, original Problems tabs and permission actions,
  dedicated MENU worker and deterministic layout-worklist equivalence.
- [Apple validation](https://github.com/Ikaring45/GModCore/actions/runs/38900338302)
  passed for production source `644e301`: strict ARM64 libraries, installable
  iPad app, Metal pipelines, Simulator launch, accessibility smoke and the
  dedicated Japanese VGUI/IME/Q/C/Problems/noclip gate. This includes the real
  App MENU actor path and stock slider layout regression. Subsequent changes
  are release metadata/documentation only, not runtime code.
- Full package XCTest completion and physical-device success are not claimed.
- The reported physical iPad crash has no crash log attached. Stack exhaustion
  is a suspected cause addressed by the worker change, not a confirmed root
  cause. Physical-device crash recovery and frame-time improvements are not
  claimed from portable tests or Simulator results.
- Existing 0.1.62 limitations remain: Settings is host-owned rather than full
  Source GameUI options; lua_strict is explicitly disabled; rotated Surface
  rectangles support exact 0/180-degree cases only.

Select package version **0.1.63** in Swift Playgrounds.
