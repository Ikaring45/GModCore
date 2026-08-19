# GModLua Lua 5.1 compatibility status

Date: 2026-08-19

## Verified result

The pure-Swift `GModLua` embedded runtime completes the Lua 5.1 official basic
test sequence through all cleanup collections:

```text
final OK !!!
cleaning all!!!!
[CONFORMANCE][PASS] final OK = true
```

The verified run executes `gc.lua` in its original `all.lua` position. It does
not replace, shorten, or classify GC as a pass. The run completed with process
exit code 0 after fetching 24 test files and performing 38 chunk loads from the
local mirror. The final 0.1.43 packaging run completed in 85.70 seconds.

Only two files are intentionally classified outside the embedded language
runtime:

- `main.lua` — PUC standalone executable, command-line, and child-process tests
- `api.lua` — PUC internal C-API test harness

Those classifications are printed as `SKIP`, never as `PASS`.

## Official test coverage in the passing run

- debug hooks, stack frames, locals, upvalues, tracebacks, and tail calls
- function calls, protected errors, closures, coroutines, and thread environments
- byte-preserving strings, patterns, formatting, literals, and source decoding
- assignments, constructors, operators, locals, loops, and varargs
- package, `require`, `module`, environments, and loader behavior
- tables, metatables, iteration, sorting, and large programs
- math library and numeric edge cases
- writable VFS, `io`, file handles, seeking, buffering, rename/remove, and EOF
- explicit GC, weak-key/value tables, userdata finalizers, resurrection ordering,
  incremental steps, `gcinfo`, and state cleanup
- the 200,000-node deep-structure GC case without relying on the Swift stack

Environment-dependent tests retain their own upstream classifications. Locale
availability, dynamic C libraries, `popen`, and internal `testC` opcode/C-hook
paths are not silently converted into language-runtime passes.

## Collector implementation

`LuaGarbageCollector` is an explicit Lua-owned heap layered over Swift ARC.
Swift ARC is used only to reclaim host storage after Lua reachability decisions.

Implemented behavior includes:

- root mark/sweep across tables, functions, native functions, userdata,
  threads, and lexical environments
- iterative worklist marking for arbitrarily deep Lua graphs
- weak keys, weak values, and combined weak tables
- reverse creation-order userdata finalization
- one-cycle finalized-userdata grace and resurrection
- objects allocated by finalizers
- finalizer error propagation
- `collectgarbage` collect/stop/restart/step/count/setpause/setstepmul
- approximate `gcinfo` accounting and automatic collection safe points
- non-closing standard `stdin`/`stdout`/`stderr` finalizers, matching Lua IO

The automatic collector uses a multi-megabyte nursery threshold. Known object
and environment adoption is O(1); normal-table `next` no longer rescans the
entire traversal history. These changes prevent the official suite from
degenerating into quadratic host work.

## Other compatibility work included in this milestone

- exact Lua 5.1 module/require caller-environment and loader-argument behavior
- loop variables receive fresh captured bindings per iteration
- Lua-to-Lua versus Lua-to-native tail-frame semantics
- parser limits, raw-byte syntax diagnostics, stack overflow guards
- official file/IO semantics over a shared writable virtual filesystem
- O(1) table iteration continuation and non-quadratic `table.sort`
- GLua syntax already accepted by the parser: `continue`, `&&`, `||`, `!`,
  `!=`, `//`, and `/* ... */`
- lexical `DEFINE_BASECLASS(...)` rewrite with multiple declarations and
  closure capture preserved

## Remaining boundaries

This result is not a claim that every host-facing GMod API is implemented.

- `string.dump` uses an internal GModLua round-trip representation; it is not
  PUC Lua 5.1 binary-chunk interoperability.
- The standalone PUC command-line program and PUC C ABI are separate products,
  not features of the embedded Swift VM.
- Final iPad filesystem, sandbox, UI, and Metal integration still require iPad
  hardware validation even though the same runtime source passes on Windows.
- Lua 5.1 conformance does not imply GLua engine completeness. Native M2 now
  supplies the bootstrap-facing Vector/Angle, ConVar, Entity identity, timer,
  in-memory SQLite, file/preset, logical resource/surface, VGUI, and Derma
  layers, but complete Entity/Player behavior, persistent realm databases, net
  transport, physics, Source assets, and platform-backed UI/rendering remain
  later compatibility layers.

## GLua bootstrap evidence

The current regression harness parses all 259 targeted files from a local,
legally installed GMod corpus. It covers the bootstrap modules, Base, all loose
autorun files, Sandbox/Spawnmenu, and TTT without redistributing those files.
The final packaging run reported 259/259 parser successes. Its independent-file
load diagnostic reported 24/259 loads because it intentionally withholds the
shared realm/bootstrap state; those missing-API classifications are not counted
as runtime passes. Ordered strict bootstrap and startup results are measured by
the separate same-state gates below.

The mount-aware bootstrap self-test verifies realm globals, nested `include`
returns, `AddCSLuaFile`, GMod module search paths, writable overlays, and
case-insensitive host lookup. Strict mode stops on missing real engine APIs;
Discovery mode can continue with explicitly recorded compatibility gaps, and
its output must not be reported as a compatibility pass.

The strict gamemode gate validates manifest/base-chain loading and real
`gamemode.Register` calls. A separate `--gmod-startup` gate now runs Base,
realm-correct loose autorun, the target gamemode, and host-dispatched lifecycle
hooks in one state. Addon mounting, CLIENT player connection, and engine entity
readiness remain explicit false/SKIP boundaries, so this is not reported as a
complete desktop startup lifecycle.

For the final 0.1.43 snapshot, fresh Swift tests pass 89/89. Strict core init
passes with 27 SERVER, 42 CLIENT, and 42 MENU includes and zero gaps. Isolated
gamemode loading passes for SERVER TTT at 59 includes and CLIENT/MENU Sandbox at
101 includes. Modeled Sandbox startup completes in SERVER and CLIENT within the
stated boundaries; TTT startup separately stops at
`gamemodes/terrortown/gamemode/init.lua:199`, where the unimplemented
network-global `SetGlobalFloat` API is first required during `Initialize`.

## Reproduction

```powershell
swift build --product GModLuaConformance
.\.build\debug\GModLuaConformance.exe --suite-dir C:\path\to\lua5.1-tests
swift test
.\.build\debug\GModLuaConformance.exe --gmod-bootstrap-selftest
```

The suite command returns non-zero for any runtime failure, including a failure
that occurs after the upstream `final OK !!!` line during cleanup.
