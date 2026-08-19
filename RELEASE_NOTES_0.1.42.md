# Garry's PAD / GModCore 0.1.42

## Lua 5.1 `final OK` with real GC

The pure-Swift runtime now completes the official Lua 5.1 basic test sequence,
including the real `gc.lua` in its original position and all final cleanup
collections. The verified Windows conformance run exits with code 0 and prints:

```text
final OK !!!
cleaning all!!!!
[CONFORMANCE][PASS] final OK = true
```

The run fetched 24 official files, performed 38 chunk loads, and classified
only two environment-specific files as skips:

- `main.lua`: standalone CLI/process behavior
- `api.lua`: PUC Lua internal C-API harness

GC is no longer skipped. The collector now provides explicit Lua reachability,
weak tables, userdata finalization and resurrection, incremental collection,
`gcinfo`, deep non-recursive marking, and explicit state-close finalization.

## Compatibility fixes

- Lua 5.1 `module`/`require` caller environments and loader arguments
- fresh captured loop bindings and correct Lua/native tail frames
- byte-preserving source diagnostics, parser limits, and stack guards
- shared writable VFS-backed `io`, file handles, buffering, seek, rename/remove
- non-quadratic table traversal, sorting, and large-program execution
- lexical `DEFINE_BASECLASS(...)` rewriting with repeated declarations
- LuaJIT-compatible GLua `bit` library

## GLua Gameplay Bootstrap M1

- SERVER, CLIENT, and MENU realm globals
- mount-priority VFS with writable overlay and deterministic case folding
- nested `include`, `AddCSLuaFile`, and GMod module search paths
- Source KeyValues V1 parsing
- strict production mode separated from diagnostic Discovery shims
- GLua type ABI primitives and metatable registry
- local-GMod corpus harness without redistributing game files or assets

The regression corpus parses all 259 targeted files from a legally installed
Garry's Mod tree. Strict loading currently reaches 21/259 files. This is a
bootstrap measurement, not a claim of full engine compatibility.

## Known boundaries

- PUC Lua 5.1 binary chunks are not interoperable yet; `string.dump` uses an
  internal GModLua round-trip format.
- Strict bootstrap in every realm next requires the real Vector
  constructor/operations. Discovery runs show that CLIENT/MENU then reach the
  missing Metal-backed `render` primitives.
- Entity/Player behavior, SQLite, net transport, VGUI/Spawnmenu, physics,
  Source assets, and Workshop execution remain incomplete.
- Windows validates the cross-platform Lua/runtime source. Swift Playgrounds,
  iPad sandbox behavior, UI, and Metal integration still require device testing.

No Garry's Mod Lua corpus, proprietary game asset, or proprietary Source/GMod
engine binary is included in this release.
