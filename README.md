# Garry's PAD / GModCore

Garry's PAD is an experimental compatibility runtime for running Garry's Mod
Lua, gamemodes, and Source assets natively on iPad. It is not a Windows
emulator or a remote-play client. The shipping architecture is Swift ARM64 +
Metal, hosted by Swift Playgrounds.

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

The native GLua bootstrap now includes M4's measured CLIENT UI order and a
paired-realm host session. CLIENT loads Derma before Base, then realm-correct
autorun, the installed postprocess/VGUI/matproxy directories, the real Default
skin, and the target gamemode. The Default skin samples
`gwenskin/GModDefault.png` directly from a legally installed VPK through a
cached platform decoder; no game asset or hard-coded palette is bundled.

A deterministic one-SERVER/many-CLIENT session now provides canonical Player
mirrors, `LocalPlayer`, client-to-server and targeted server-to-client net
delivery, forwarded console commands, generation-safe disconnect cleanup, and
explicit host pumping. Entity-family userdata have realm-local Lua sidecar
tables with exact `GetTable`/`SetTable` identity, method precedence, stale/NULL
behavior, and GC roots. `Player(number)` correctly uses UserID while
`Entity(number)` uses EntIndex.

Strict paired Sandbox and TTT both exit 0 through the SERVER and CLIENT
`InitPostEntity` stages represented by the harness; the TTT run delivers four
queued cross-realm events. This is a modeled startup result, not a claim that
either gamemode is playable. Addon discovery, Steam authentication, live
engine entity readiness, real sockets/channels, prediction, and desktop
startup completion remain false/SKIP boundaries. Spawnmenu Lua is loaded and
registered, but the runner does not dispatch `OnGamemodeLoaded` to instantiate
the menu.

The logical VGUI/Surface layer now covers measured docking, render-command,
text, focus, and pointer plumbing, but it is not yet connected to the existing
app/Metal platform view or draw backend. General VMT/VTF shader/material
resolution is also incomplete; the installed Default PNG atlas path is
narrower than full material/rendering compatibility. VPK/image inputs are
trusted installed content in this milestone, not a hardened untrusted-Workshop
ingestion path.

The 0.1.45 release commit passes 170/170 Swift tests and the complete Engine
strict-concurrency gate with warnings treated as errors. Its GC-enabled
official Lua 5.1 run exits 0 through `final OK` in 92.84 seconds, with 38 chunk
loads and two classified skips. The installed-GMod parser gate passes 259/259
files; the deliberately independent-file load diagnostic reaches 26/259.
These are separate results: parsing or independently loading a corpus file
does not claim that every engine API it calls is implemented. Exact details
are recorded in
[`LUA51_CONFORMANCE_STATUS.md`](LUA51_CONFORMANCE_STATUS.md) and the 0.1.45
release notes.

## Verified native path

- iPad / Swift Playgrounds host
- ARM64 Swift runtime
- Metal rendering on Apple M5 GPU
- approximately 120 render FPS in the current preview
- fixed simulation interval `0.015` seconds (approximately 66.67 ticks/s)
- render and simulation clocks are independent
- GMod-style developer console with direct Lua and `lua_run` input

Windows is used for fast Lua compatibility iteration only. The same pure-Swift
runtime source is consumed by Swift Playgrounds; final UI, Metal, filesystem,
and sandbox behavior still require iPad validation.

## Architecture

```text
Swift Playgrounds / iPadOS
├─ GModApp       console, app lifecycle, input
├─ GModMetal     ARM64 Metal renderer
├─ GModEngine    realms, VFS mounts, include/require boot flow
└─ GModLua       pure-Swift Lua 5.1 + GLua compatibility runtime
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

The repository contains reproducible analysis and a regression harness, but no
copied Garry's Mod Lua corpus or proprietary assets:

- [`Docs/GLuaAnalysis/01_BOOTSTRAP_MODULES.md`](Docs/GLuaAnalysis/01_BOOTSTRAP_MODULES.md)
- [`Docs/GLuaAnalysis/02_EXTENSIONS.md`](Docs/GLuaAnalysis/02_EXTENSIONS.md)
- [`Docs/GLuaAnalysis/03_GAMEMODES_CORPUS.md`](Docs/GLuaAnalysis/03_GAMEMODES_CORPUS.md)
- [`Docs/GLuaAnalysis/04_RUNTIME_M1_IMPLEMENTATION.md`](Docs/GLuaAnalysis/04_RUNTIME_M1_IMPLEMENTATION.md)
- [`Docs/GLuaAnalysis/05_NATIVE_BOOTSTRAP_M2.md`](Docs/GLuaAnalysis/05_NATIVE_BOOTSTRAP_M2.md)
- [`Docs/GLuaAnalysis/06_REALM_NETWORKING_M3.md`](Docs/GLuaAnalysis/06_REALM_NETWORKING_M3.md)
- [`Docs/GLuaAnalysis/08_DERMA_SHARED_SESSION_M4.md`](Docs/GLuaAnalysis/08_DERMA_SHARED_SESSION_M4.md)
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

This repository does not include Garry's Mod game assets, Valve game assets,
proprietary engine binaries, leaked source code, or Workshop content. Users are
responsible for supplying legally obtained content for local compatibility
testing.
