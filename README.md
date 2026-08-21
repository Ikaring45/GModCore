# Garry's PAD / GModCore

Garry's PAD is an experimental compatibility runtime for running Garry's Mod
Lua, gamemodes, and Source assets natively on iPad. It is not a Windows
emulator or a remote-play client. The shipping architecture is Swift ARM64 +
Metal, with a checked-in iPadOS app host and a Swift Playgrounds-compatible
package.

The objective is compatibility, not a mobile sandbox that merely resembles
Garry's Mod. Wherever practical, the original Lua gamemode and Spawnmenu code
should run on a compatible runtime instead of being reimplemented as a separate
Swift UI.

## Current milestone

The pure-Swift `GModLua` runtime now runs the Lua 5.1 official basic test corpus
through `final OK !!!` and all cleanup collections. The passing Windows run
executes the real `gc.lua`, including weak tables, userdata finalizers,
incremental steps, and its 200,000-node deep structure. CORE language, debug,
calls, strings, literals, attributes/modules, closures, errors, math, sort,
large-program, and file/IO tests run in their original order.

The following categories remain deliberately separate from that result:

- `main.lua`: standalone CLI/process behavior, not the embedded language runtime
- `api.lua`: PUC Lua internal C-API test, not applicable to a pure-Swift VM
- PUC binary chunks: `string.dump` currently provides an internal GModLua
  round-trip format, not PUC bytecode interoperability

No skipped or unfinished feature is reported as a pass. See
[`LUA51_CONFORMANCE_STATUS.md`](LUA51_CONFORMANCE_STATUS.md) for the exact
verification boundary.

The 0.1.53 release-candidate branch carries the paired GLua runtime into a
bounded playable Sandbox slice. It owns one SERVER and one CLIENT, loads the
original authorized Base/Sandbox/Derma/Spawnmenu Lua in measured order,
creates the real `g_SpawnMenu`, and renders its Surface commands through the
Metal overlay. The stock Weapons tab, tree categories, ContentIcons, tool
controls, SpawnIcons, compact-layout scroll bar, and Lua callbacks are driven
by actual pointer samples rather than a replacement Swift spawn menu.

A deterministic one-SERVER/many-CLIENT session now provides canonical Player
mirrors, `LocalPlayer`, client-to-server and targeted server-to-client net
delivery, forwarded console commands, generation-safe disconnect cleanup, and
explicit host pumping. Entity-family userdata have realm-local Lua sidecar
tables with exact `GetTable`/`SetTable` identity, method precedence, stale/NULL
behavior, and GC roots. `Player(number)` correctly uses UserID while
`Entity(number)` uses EntIndex.

The Source compatibility adapter supplies generation-safe Entity handles,
SERVER fixed ticks, independent CLIENT frame/fixed-tick clocks, world-brush
traces, and a bounded ground-walk slice. World rendering now carries BSP
texinfo UVs, generated-cubemap fallback, worldspawn sky, HDR lightmaps,
recursive displacement meshes, and the dedicated construct water path into
Metal. The authorized `gm_construct` and `gm_flatgrass` BSP/NAV/AIN fixtures
are bundled and both run deterministic startup, trace, mesh, and movement
regressions. The iPadOS 16 host lives under `Apps/GarrysPAD` and presents
`GModMainView`; the package-only host is no longer the sole app entry point.

The repository includes a manifest-locked subset of project-authorized base
GMod content needed by this slice: fonts, client Lua, PNGs, 72 VMTs, 46 VTFs,
and the two maps. It deliberately excludes Workshop/cache/addon content and
does not broaden the bundle from arbitrary runtime paths. VMT/VTF and bitmap
decoding, Surface capture, CPU caches, and per-frame GPU upload all have
explicit allocation limits.

The app now mounts a user-selected content ZIP transactionally, validates its
root manifest and critical hashes before activation, and can stream CRC and
SHA-256 verification across every authorized payload with real progress and
cancellation. Home, Loading, Pause, Options, Problems, audio, and normal-play
controls are connected to that mounted source. Pinch/double-tap zoom is blocked
in Home while taps, scrolling, Angular commands, and persisted English/Japanese
selection remain live. Normal play does not expose the old Render Preview,
map buttons, counters, Console, or diagnostic frame unless Developer
diagnostics is explicitly enabled.

This is not full Garry's Mod playability. Static props and Studio-model
rendering, arbitrary addon mounting, Steam/authentication, sockets,
prediction, displacement collision, complete step/water/ladder movement,
dynamic entity physics, and a complete weapon/tool runtime remain explicit
boundaries. The exercised stock Weapons ContentIcon now grants and selects a
Source-backed logical weapon, and the exercised Button-tool SpawnIcon updates
the real client tool mode/model path. Networked/predicted SWEP behavior and
prop/entity spawning, models, physics, and undo remain explicit unsupported
boundaries rather than being presented as successful spawns.

The 0.1.53 candidate Windows integration gate passes 479 XCTest cases plus
11/11 Swift Testing Source-filesystem cases, with warnings treated as errors.
The real 4.876 GB content pack validates all 2,641 authorized payload SHA-256
values and passes Home background, both maps, six-face painted sky, water,
materials, Sandbox startup, and movement gates. Embedded Metal source and
pipeline contracts are checked locally, but Apple package/app/Metal build,
Simulator launch, and physical-iPad behavior remain CI/device gates rather
than inferred passes.

The released 0.1.45 commit separately passes 170/170 Swift tests and the complete Engine
strict-concurrency gate with warnings treated as errors. Its GC-enabled
official Lua 5.1 run exits 0 through `final OK` in 92.84 seconds, with 38 chunk
loads and two classified skips. The installed-GMod parser gate passes 259/259
files; the deliberately independent-file load diagnostic reaches 26/259.
These are separate results: parsing or independently loading a corpus file
does not claim that every engine API it calls is implemented. Exact details
are recorded in
[`LUA51_CONFORMANCE_STATUS.md`](LUA51_CONFORMANCE_STATUS.md) and the 0.1.45
release notes.

## Native path

- checked-in iPadOS application host plus Swift Playgrounds-compatible library
- ARM64 Swift runtime
- existing Metal preview previously exercised on Apple M5 GPU
- the new Sandbox world/Surface integration still requires its physical-iPad gate
- fixed simulation interval `0.015` seconds (approximately 66.67 ticks/s)
- render and simulation clocks are independent
- GMod-style developer console with direct Lua and `lua_run` input

Windows is used for fast runtime compatibility iteration. Final SwiftUI,
Metal, lifecycle, touch-cancellation, glyph, and performance behavior still
requires the checked-in Apple CI and a physical-iPad validation pass.

## Architecture

```text
Apps/GarrysPAD / Swift Playgrounds / iPadOS
├─ GModApp          SwiftUI lifecycle, input, diagnostics
├─ GModMetal        ARM64 world and Surface renderer
├─ GModGameSession  paired Sandbox actor lane and map runtime
├─ GModGameAssets   manifest-locked authorized content
├─ GModEngine       Source/GLua realms, VFS, net, VGUI, trace
└─ GModLua          pure-Swift Lua 5.1 compatibility runtime
```

The existing `GModCore` C ABI remains available for native engine experiments,
but Lua execution is not delegated to a Windows binary or an emulated PUC Lua
process.

## Windows Lua conformance runner

Install the official Swift toolchain, then build only the cross-platform
diagnostic executable:

```powershell
swift build --product GModLuaConformance
```

Run an individual file or diagnostic snippet:

```powershell
swift run GModLuaConformance --file .\path\to\test.lua
swift run GModLuaConformance --trace-file .\path\to\test.lua
swift run GModLuaConformance --eval 'print(table.getn({10, 20, 30}))'
swift run GModLuaConformance --eval-name '=diagnostic' 'print(debug.getinfo(1).currentline)'
```

Run an already downloaded official suite:

```powershell
.\.build\debug\GModLuaConformance.exe --suite-dir C:\path\to\lua5.1-tests
```

`--trace-file` preserves Lua byte strings and prints a Lua traceback for failed
assertions. A CORE failure returns a non-zero process exit code.

## GMod compatibility research

The repository contains reproducible analysis, a regression harness, and an
explicitly authorized/manifested base-content subset. It does not contain an
unbounded installed-game corpus or Workshop/addon cache:

- [`Docs/GLuaAnalysis/01_BOOTSTRAP_MODULES.md`](Docs/GLuaAnalysis/01_BOOTSTRAP_MODULES.md)
- [`Docs/GLuaAnalysis/02_EXTENSIONS.md`](Docs/GLuaAnalysis/02_EXTENSIONS.md)
- [`Docs/GLuaAnalysis/03_GAMEMODES_CORPUS.md`](Docs/GLuaAnalysis/03_GAMEMODES_CORPUS.md)
- [`Docs/GLuaAnalysis/04_RUNTIME_M1_IMPLEMENTATION.md`](Docs/GLuaAnalysis/04_RUNTIME_M1_IMPLEMENTATION.md)
- [`Docs/GLuaAnalysis/05_NATIVE_BOOTSTRAP_M2.md`](Docs/GLuaAnalysis/05_NATIVE_BOOTSTRAP_M2.md)
- [`Docs/GLuaAnalysis/06_REALM_NETWORKING_M3.md`](Docs/GLuaAnalysis/06_REALM_NETWORKING_M3.md)
- [`Docs/GLuaAnalysis/08_DERMA_SHARED_SESSION_M4.md`](Docs/GLuaAnalysis/08_DERMA_SHARED_SESSION_M4.md)
- [`Docs/GLuaAnalysis/09_SOURCE_MATERIAL_BOUNDARY.md`](Docs/GLuaAnalysis/09_SOURCE_MATERIAL_BOUNDARY.md)
- [`Docs/GLuaAnalysis/10_IPAD_PLAYABLE_SLICE.md`](Docs/GLuaAnalysis/10_IPAD_PLAYABLE_SLICE.md)
- [`GMOD_BOOT_SEQUENCE.md`](GMOD_BOOT_SEQUENCE.md)
- [`Tests/GModCorpus/README.md`](Tests/GModCorpus/README.md)

The current local regression corpus covers the real bootstrap modules, Base,
all loose `lua/autorun` files, Sandbox including the nested Spawnmenu/VGUI
loader tree, and TTT as a large compatibility corpus. The harness reads a
legally installed local game directory and records hashes and diagnostics; it
does not redistribute those files. Its parser gate passes 259/259 files; its
independent-file load diagnostic reaches 26/259 without shared bootstrap state,
so that diagnostic is not presented as whole-corpus runtime compatibility.

## Compatibility roadmap

Work proceeds from the bottom of the actual GMod boot chain:

1. Lua 5.1 runtime and collector semantics
2. GLua syntax, type ABI, and base primitives
3. mount-aware VFS, `include`, `require`, and `AddCSLuaFile`
4. `SERVER`, `CLIENT`, and `MENU` realm bootstraps
5. original `lua/includes/init.lua` and core modules
6. Base Gamemode, autorun/addons, and Sandbox
7. Entity/Player registries, hooks, concommands, file/SQL, and net transport
8. VGUI/Spawnmenu compatibility using the original Sandbox Lua
9. BSP/MDL/VTF/VMT/VPK/GMA assets, physics, rendering, and Workshop addons

The observed high-level order is:

```text
SERVER: Base -> autorun/addons -> target -> PostGamemodeLoaded -> Initialize -> InitPostEntity
CLIENT: Derma -> Base -> autorun -> postprocess/VGUI/matproxy -> Default skin -> target -> PostGamemodeLoaded -> Initialize -> player connection -> InitPostEntity
```

## Project scope

GModCore is independent research and is not affiliated with or endorsed by
Facepunch Studios, Valve Corporation, or Garry Newman. Garry's Mod, Source,
Steam, and related names and trademarks belong to their respective owners.

This repository includes only the project-authorized base-game files declared
by its asset manifests and required by the current iPad slice. It does not
include proprietary engine binaries, leaked source, Workshop/cache/addon
content, or undeclared installed-game files. Expansion of that whitelist is an
explicit provenance and review operation, never an automatic copy of a user's
installation.
