# GLua native bootstrap M2

This milestone replaces the discovery-only bootstrap objects from M1 with
state-local native Swift primitives. It is measured against a locally
installed Garry's Mod tree, but no game Lua source, asset, or engine binary is
redistributed by this repository.

The compatibility result always comes from `GMLuaBootstrapMode.strict`.
Discovery mode remains diagnostic only and cannot produce a PASS.

## Verified Lua foundation

The underlying pure-Swift VM still completes the upstream Lua 5.1 basic test
sequence through `final OK !!!`, every cleanup collection, and explicit state
close. The run executes the real `gc.lua`; GC is not skipped or simulated.

The embedded-runtime classifications remain unchanged:

- `main.lua` is the standalone PUC Lua command-line/process harness.
- `api.lua` is the PUC internal C-API harness.

Those two files are printed as classified skips. They are not counted as
language-runtime passes. PUC-compatible binary chunks also remain outside the
verified result: `string.dump` currently uses a private GModLua round-trip
representation.

## Native GLua substrate

### Values and type ABI

- LuaJIT-compatible `bit` operations and GLua type IDs/metatable lookup.
- Native mutable `Vector` and `Angle` userdata with aliases, arithmetic,
  comparisons, normalization, basis conversion, and the methods required by
  the current Base/Sandbox corpus.
- Native state-local ConVar identity, documented core getters/setters, realm
  flags, bounds, and the FCVAR constants used by the measured corpus.
- Native Entity/Player identity registry, canonical `NULL`, basic validity and
  enumeration, and deterministic replacement/removal behavior.
- The ACT/PLAYER/PLAYERANIMEVENT/GESTURE_SLOT constants referenced by the
  measured Base, Sandbox, and TTT corpus are validated against the public enum
  values.
- Publicly documented SF/CT/NPC_STATE constants are installed with their
  documented realm availability instead of ad-hoc autorun sentinels.

This does not yet provide the complete engine-owned Entity/Player method set,
network state, physics objects, or every public ACT constant.

### Time and host simulation

`CurTime` and the documented named-timer control surface are backed by a
state-local scheduler. The host advances it from the fixed `0.015` simulation
tick, so callbacks run on the Lua realm's owning thread rather than a wall
clock worker. Callback errors are isolated and returned to the host, and live
callbacks are retained as Lua GC roots.

The current iPad console owns a SERVER realm. Its timer scheduler is connected
to the Metal preview's fixed-tick signal. Separate CLIENT/MENU realm lifecycle
and clock ownership are still required before their timers can be presented as
an end-to-end iPad gameplay result.

### Host session, engine, and console state

`game.MaxPlayers`, `game.GetMap`, `game.SinglePlayer`, `game.IsDedicated`,
`engine.GetGames`, and client demo-state queries read explicit live host
snapshots. A disconnected iPad runtime raises a precise error instead of
guessing Source/Steam state. The conformance executable injects labelled
deterministic fixtures.

`RunConsoleCommand` distinguishes Lua-owned ConVars, registered Lua
`concommand` callbacks, and host-owned engine commands. Unknown, rejected, and
disconnected commands fail. The headless corpus host recognizes only the exact
engine command needed by the measured TTT initialization path and logs that
allowlist; it is not a general Source console implementation.

### Files and persistence

- Priority-ordered, case-insensitive virtual mounts with containment-checked
  host directories and a writable overlay.
- Persistent whiteouts prevent files deleted from an upper writable layer from
  reappearing from a lower read-only mount after a runtime restart.
- Explicit virtual directories and directory enumeration support the GLua
  `file` library without exposing host paths.
- Desktop preset persistence uses per-file Valve KeyValues documents under
  `settings/presets/<group>/<number>-<name>.txt`, rather than the earlier
  private Garry's PAD snapshot format.
- `sql.Query` uses a state-local in-memory SQLite database with extension
  loading and database attachment disabled.

Mounted game content remains read-only. Persistent realm databases, the full
Source search-path graph, VPK/GMA enumeration, timestamps, asynchronous reads,
and every binary `File` method are later milestones.

### Client bootstrap registries

- Logical IMaterial/ITexture identities and screen-effect render-target names.
- Logical resource-precache request tracking without claiming asset decode.
- `surface.GetTextureID`/`SetTexture` command state.
- `surface.CreateFont`, `SetFont`, and `GetTextSize` with deterministic logical
  metrics and an injectable platform-measurement boundary.
- Live `ScrW`/`ScrH` viewport state and the `ScreenScale`/`ScreenScaleH`
  helpers in client-capable realms.
- Native Panel identity plus `vgui.Register`, `GetControlTable`, `Exists`,
  `Create`, and `GetAll`.
- Derma control and skin registries needed to load the original client VGUI
  bootstrap.
- Logical Panel geometry, hierarchy, visibility, alpha, input flags, paint
  flags, HUD parenting, and Z position. `DPanel` remains the original Lua
  control loaded by `lua/includes/vgui_base.lua`; it is not replaced by a fake
  native class.

Material and texture descriptors are unresolved, font descriptors have no
UIKit/CoreText glyph backing, and panels have no UIKit/Metal view backing.
VMT/VTF decoding, layout, input, paint dispatch, draw submission, and the full
Panel method surface are not reported as implemented.

## Gamemode execution gate

`GMLuaGamemodeLoader` reads `gamemode.txt`, validates base chains before
registration, selects the realm entry point, injects the engine-owned
`GM`/`GAMEMODE` globals, and calls the real Lua `gamemode.Register` function.
It reports partial registration and exact failure phase/path instead of
silently continuing.

The conformance executable exposes both isolated loading and modeled startup:

```powershell
GModLuaConformance.exe --gmod-gamemode <garrysmod-root> <realm> <strict|discovery> <name>
GModLuaConformance.exe --gmod-startup <garrysmod-root> <server|client> <strict|discovery> <name>
```

The first gate deliberately prints `autorun=not-run addons=not-run`. The second
runs Base once, direct shared autorun A-Z, realm autorun A-Z, the target
gamemode, and host `hook.Call` dispatch for the measured lifecycle events in a
single state. CLIENT first runs the engine-invoked
`lua/includes/vgui_base.lua` stage. Direct autorun files and their transitive
`include()` paths are reported separately.

The startup report still says `desktopStartupComplete=false`: addon/GMA/VPK
mounting is skipped, CLIENT player connection is skipped, and engine entity
readiness is false. `InitPostEntity` here proves hook dispatch and the code
reached by the corpus, not a live Source world.

## Strict evidence for M2 packaging

The following results are reproduced from the current native implementation:

| Entry | Strict result | Evidence boundary |
|---|---|---|
| SERVER `lua/includes/init.lua` | PASS | 27 nested includes, 4 client files, 5 commands, 0 gaps |
| CLIENT `lua/includes/init.lua` | PASS | 42 nested includes, 0 gaps |
| MENU `lua/includes/init.lua` | PASS | 42 nested includes, 0 gaps |
| SERVER Base | PASS | registered through the real gamemode loader |
| SERVER Sandbox | PASS | Base chain and Sandbox entry complete |
| CLIENT/MENU VGUI bootstrap | PASS | core init plus original `vgui_base.lua`; logical registry only |
| CLIENT/MENU Sandbox isolated load | PASS | Base chain plus Sandbox; 101 includes, 0 gaps in each realm |
| SERVER Sandbox modeled startup | PASS | Base, 7 shared autorun, 1 server autorun, Sandbox, 3 hook dispatches; addons/entity readiness excluded |
| CLIENT Sandbox modeled startup | PASS | 54 VGUI includes, Base, 7 shared + 2 client autorun, Sandbox, 3 hook dispatches; player/addons/entity readiness excluded |
| SERVER TTT load/registration | PASS | Base chain, 14 language files, 59 includes, 60 client files, 34 commands, 0 gaps |
| SERVER TTT modeled startup | FAIL at known boundary | reaches `Initialize`; `gamemodes/terrortown/gamemode/init.lua:199` calls the unimplemented network-global `SetGlobalFloat` API |

M3 realm audit correction: the two MENU rows above were diagnostics that ran
the gameplay `init.lua`/Sandbox paths with a menu state. They are preserved as
the historical M2 measurements but are not valid MENU startup evidence. The
realm-correct gate is `lua/includes/init_menu.lua`; M3 completes it
with 23 includes, zero gaps, and does not expose gameplay `net`, Entity, or
Player APIs.

Final 0.1.43 packaging verification also passes 89/89 Swift tests, the official
Lua 5.1 suite with GC enabled (exit 0, 38 chunk loads, 85.70 seconds), the
259/259 installed-GMod parse gate, the Engine strict-concurrency build, and
frontend parsing of 31 Engine/App/Metal Swift files. An exact next missing API
is a compatibility blocker, not a skipped success.

The independent-file corpus diagnostic loads 24/259 files because it
deliberately provides no ordered shared bootstrap state. That number is an
expected diagnostic classification, not a whole-corpus runtime PASS.

## Copyright-safe regression strategy

All checked-in Lua fixtures are small original programs that exercise public
contracts. The large corpus runner reads the user's installed game tree in
place and stores paths, hashes, counts, and diagnostics only. Scratch build
directories and local corpus data are excluded from release archives.

## Remaining major layers

- addon/GMA/VPK discovery, CLIENT player connection, and live entity readiness;
- complete file search paths, persistent realm SQL, and engine-owned ConVars;
- net bitstreams, realm transport, network globals, NetworkVar/NW/DT behavior;
- complete Entity/Player/Weapon/Vehicle and physics APIs;
- VGUI layout/input/paint and Spawnmenu runtime behavior;
- BSP/MDL/VTF/VMT/VPK/GMA/Workshop loading and Source asset resolution;
- Metal scene rendering, render targets, materials, lighting, and postprocess;
- iPad hardware verification of the new runtime layers.

M2 is therefore a native bootstrap milestone, not a claim that Garry's Mod or
all GLua engine APIs are complete.
