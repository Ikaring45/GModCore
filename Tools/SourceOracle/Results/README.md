# Recorded Windows oracle results

## 2026-08-19 / schema 1

Pre-hardening raw capture:
`27d364351a1949df9ef6cbe18a928673.json`

This file predates strict launch-token validation. Its own
`command_line_enabled` is false and its command-line run ID is `manual`, so it
is not an authenticated runner result and must not be promoted to a golden
contract. The observations below are provisional leads for a future, safely
authenticated rerun.

Observed host:

- Garry's Mod `VERSIONSTR` `2026.08.13` (`VERSION` `260813`)
- `x86-64` branch, LuaJIT `x64`
- Steam app manifest build ID `24721252`
- `gm_flatgrass`, single-player listen server

High-value contracts from this capture:

- `engine.TickInterval()` and tick `FrameTime()` are the Float value
  `0.014999999664723873`, not an exact binary Double `0.015`.
- The server `Think` hook is observed before the `Tick` hook at the same
  `CurTime()` in this configuration.
- `Entity(-1) == NULL`; `IsValid(NULL)` is false; `NULL:EntIndex()` succeeds
  and returns `0`; `NULL:GetClass()` raises `Tried to use a NULL entity!`.
- `Entity(0)` reports `EntIndex() == 0` and class `worldspawn`, while
  `IsValid(Entity(0))` is false.
- Removing an entity and immediately creating another did not reuse its
  EntIndex (`70` then `71`).
- A swept ±4 hull against explicit ±16 entity collision bounds hit at
  `x = -20.03125`, fraction `0.343505859375`; the extra `0.03125` is Source's
  collision distance epsilon. Hit normal was `(-1,0,0)`, while the Lua trace
  `Normal` field was the normalized movement direction `(1,0,0)`.
- Starting inside the entity returned `Fraction = 0`, `StartSolid = true`,
  `AllSolid = false`, and `FractionLeftSolid = 0`, including the short trace
  whose endpoint remained inside.
- The case-varied GAME and LUA reads both found the same addon file.
- `Material("models/debug/debugwhite")` resolved as non-error,
  `VertexLitGeneric`, 64×64.

The line trace and hull trace intentionally differ. A line can exercise the
entity's hitbox path and returned contents `0x40000001`; the hull used the
collision bounds and returned `CONTENTS_SOLID`. Do not collapse these two
paths into one generic AABB result.

`03b25273da714b0fa28468a97145a751.json` is an earlier pre-hardening capture from
the same build. It established the NULL `GetClass` error and initial trace
behavior, but its helper encoded a spurious `error` string for successful
protected calls and it set collision bounds before `Spawn`; use the canonical
capture above for provisional comparison only.

`client-be355489facd425eb09ed844299d4d35.json` is likewise a pre-hardening
client capture. It was recorded before the runner required exact `run_id`,
`enabled`, `command_line_enabled`, schema, and realm matches. Preserve it as raw
diagnostic evidence, but do not use it as release acceptance evidence.
