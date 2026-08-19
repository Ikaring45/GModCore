# Garry's PAD / GModCore 0.1.43

## Native GLua bootstrap M2

This release moves the real Garry's Mod bootstrap beyond diagnostic shims.
SERVER, CLIENT, and MENU now use state-local Swift implementations for the
value types and registries required by the measured bootstrap path.

Highlights:

- native Vector/Angle userdata and GLua type ABI integration;
- native ConVar registry plus corpus-used ACT/PLAYER and public NPC enum values;
- Entity/Player identity registry with canonical `NULL`;
- explicit host snapshots for game session facts, mounted games, and demo state;
- `RunConsoleCommand` dispatch across Lua ConVars, registered Lua commands,
  and explicitly connected host engine commands;
- host-driven CurTime/timer scheduler connected to the fixed SERVER tick;
- state-local SQLite query surface with unsafe extension/attachment paths
  disabled;
- logical IMaterial/ITexture/resource-precache identities;
- surface texture and font registries with explicit renderer/platform
  boundaries;
- client viewport metrics (`ScrW`, `ScrH`, and screen scaling helpers);
- native VGUI Panel and Derma control/skin registries;
- validated Base-first gamemode loader and a strict same-state startup
  orchestrator for realm-correct loose autorun and lifecycle hook dispatch;
- engine-invoked CLIENT VGUI bootstrap plus logical Panel state sufficient for
  the original Lua `DPanel` and Base voice panel startup path;
- directory-aware mounted VFS, persistent whiteouts, GLua file operations,
  desktop per-file KeyValues presets, and priority-correct file/directory type
  shadowing.

The strict runner loads the real installed GMod tree in place. It does not
copy or redistribute game Lua or assets.

## Lua 5.1 regression result

The pure-Swift VM still completes the official Lua 5.1 basic test sequence,
including the real `gc.lua`, weak tables, finalizers, incremental collection,
large programs, file/IO tests, all cleanup collections, and explicit state
close:

```text
final OK !!!
cleaning all!!!!
[CONFORMANCE][PASS] final OK = true
```

The final Windows packaging run completed in 85.70 seconds with process exit
code 0, 24 fetched test files, 38 chunk loads, and two classified skips. The
real `gc.lua` remained enabled in its original test order.

`main.lua` (standalone CLI/process harness) and `api.lua` (PUC internal C-API
harness) remain explicitly classified skips. They are not reported as passes.

## Honest boundaries

This is a bootstrap release, not a claim of complete Garry's Mod execution.

- Material/texture/font/panel objects currently preserve identity and load
  contracts but do not yet have VMT/VTF, UIKit/CoreText, or Metal backing.
- Entity/Player, net transport, physics, Source assets, Workshop/GMA, and the
  complete Panel API remain incomplete.
- SQLite is currently state-local and in-memory rather than the persistent
  desktop realm databases.
- Strict SERVER and CLIENT Sandbox runs complete every currently modeled stage:
  Base, loose shared/realm autorun, Sandbox, and `PostGamemodeLoaded`,
  `Initialize`, and `InitPostEntity` hook dispatch. Addon discovery remains
  skipped; CLIENT player connection and engine entity readiness remain false.
- TTT's full Lua load/registration gate passes, but its startup lifecycle is a
  separate result and currently stops at the unimplemented network-global API
  `SetGlobalFloat` at `gamemodes/terrortown/gamemode/init.lua:199` during
  `Initialize`.
- Headless game/engine/console values are explicitly labelled deterministic
  fixtures. The iPad runtime does not invent them when no host is connected.
- File timestamps, asynchronous reads, the full mounted Source search-path
  graph, and all binary File methods remain later work.
- PUC Lua 5.1 binary chunks are not interoperable; `string.dump` uses an
  internal GModLua round-trip format.
- Windows verifies the shared cross-platform runtime. The new host layers still
  require Swift Playgrounds/iPad hardware validation. Apple-source parsing and
  the shared Engine's Swift 6 strict-concurrency build pass, but that is not an
  iPad build or hardware result.

## Packaging verification

- fresh Swift test run: 89 tests, 0 failures;
- official Lua 5.1 sequence: exit 0, `final OK`, GC enabled;
- installed-GMod priority corpus: 259/259 files parse successfully;
- independent-file load diagnostic: 24/259 loads as expected without shared
  bootstrap state; this is not a whole-corpus runtime pass;
- strict installed-GMod core bootstrap: SERVER, CLIENT, and MENU pass with zero
  compatibility gaps (27/42/42 includes respectively);
- isolated strict gamemode loading: SERVER TTT passes with 59 includes; CLIENT
  and MENU Sandbox pass with 101 includes each;
- strict installed-GMod Sandbox modeled startup: SERVER and CLIENT complete all
  currently modeled stages while retaining the boundaries above;
- Swift 6 strict-concurrency Engine build and frontend parsing of 31
  Engine/App/Metal Swift files pass on Windows.

No Garry's Mod Lua corpus, proprietary game asset, or proprietary engine
binary is included in this release.
