# Physical-device log follow-up (2026-10-18 JST)

The supplied log shows successful local-server startup and clean teardown, but
not full game compatibility. `maxplayers=2` menu commands still start a one-player
session; they are not implemented multiplayer configuration.

## Changes

- Add `RealTime` as an unscaled host uptime snapshot, stable across calls within
  a frame; refresh before CLIENT/MENU VGUI callbacks and SERVER Think/timers.
  Keep `SysTime` live/high-resolution and `CurTime` simulation-owned.
  Contract: https://wiki.facepunch.com/gmod/Global.RealTime
- Add `Panel:CursorPos` using the current registry pointer and live nested
  screen origin, sharing ScreenToLocal validity/cycle checks.
- Endpoint validation recognizes both actual-start and centered Ray_t Float
  equations already used by collision providers. This avoids false HitPos
  inconsistency from reassociation without expanding the absolute tolerance.
  Regression exercises map-scale rounding and still rejects a 1-unit corruption.

## Remaining, not hidden

MENU map/language/news/addon/server-browser callbacks and launch convars;
external URL routing; users.txt startup warning; unsupported AI command hosts;
player editor nil selection; empty table random interval; stuckRecovery;
native weapon_357 projection; separate c_arms rendering. These require actual
behavior and are not fixed by silencing diagnostics or no-op command handlers.

The reported HitPos crash has no exact replay trace in the user log. The
rounding defect is a concrete candidate, not confirmed attribution of every
inconsistent-provider result. Physical-device retest remains required.

Validation: 105 Windows timing/VGUI/world-walk tests passed. CursorPos nested
pointer coordinates and stable unscaled RealTime have direct regressions.
The endpoint regression finds actual Float reassociation differences while
retaining rejection of a 1-unit corrupted endpoint. Notification suite also
passed in the earlier 68-test timing/VGUI run. Apple/device checks pending.
