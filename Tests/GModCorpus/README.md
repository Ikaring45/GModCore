# GLua Gameplay Bootstrap M1 corpus harness

This directory turns the three reports under `Docs/GLuaAnalysis/` into an
automated source-fidelity gate without redistributing Garry's Mod Lua files.
The harness reads a local install and writes only paths, SHA-256 hashes,
classifications, and diagnostics to its report. Its default `gmod` runtime
invokes `GModLuaConformance --gmod-file ... server strict` once per source,
so realm globals, the mounted VFS, `include`, and the GMod module search path
are present while missing engine APIs still fail at first use.

## What is tested now

- Priority bootstrap: `includes/init.lua` and the five core modules.
- Priority extensions: string, table, math, file, net, entity, and player.
- Base Gamemode: 19 files.
- `lua/autorun`: 34 files.
- Sandbox and Spawnmenu: 50 files plus the global `drive_sandbox.lua`
  fallback source.
- TTT T0 corpus: 142 files.
- Gameplay aggregate: 246 files; complete priority aggregate: 259 files.

The conformance executable parses the entire chunk before executing it. The
harness therefore records a runtime missing-API failure as **parse pass, load
fail**. It never turns a runtime blocker into a parser failure or a false
overall load pass.

Diagnostic classification is deliberately conservative. Lexer/parser and
decode errors are exact. Missing-API and VFS categories are heuristic until
the runtime exposes structured errors. Any diagnostic that does not match an
explicit rule remains `UNCLASSIFIED-RUNTIME` instead of being guessed into a
PASS category.

## Windows usage

From the package directory:

```powershell
./Tests/GModCorpus/run_m1_corpus.ps1 -SelfTest

./Tests/GModCorpus/run_m1_corpus.ps1 `
  -GModRoot "C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod" `
  -Gate parse
```

If Swift was installed after the current terminal/app process started, refresh
the process environment before running the commands:

```powershell
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = "$machinePath;$userPath"
$env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
```

An executable that terminates without any diagnostic (for example because a
Swift runtime DLL is absent from `PATH`) is classified as `[FAIL][HARNESS]`;
it is never counted as a Lua parser result.

`-Gate parse` is the current regression gate. Runtime failures are still
listed and classified, but only decode/parser/timeout/corpus-drift failures
make this gate fail. Use `-Gate load` once the M1 substrate should load every
file:

```powershell
./Tests/GModCorpus/run_m1_corpus.ps1 `
  -GModRoot "C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod" `
  -Gate load
```

Useful options:

- `-Cohort bootstrap-modules,priority-extensions` runs selected cohorts.
- `-RuntimeMode gmod` is the default production gate. It uses the strict GMod
  bootstrap and never supplies placeholder engine objects.
- `-RuntimeMode gmod-discovery` enables explicitly diagnostic scaffolds. A
  source that touches any scaffold is recorded as `[SKIP][DISCOVERY]` with
  `loadPassed=false`, even if it reaches the end of the file.
- `-RuntimeMode standalone` uses the bare `--file` runner for parser-only
  comparisons without realm/VFS bootstrap state.
- `-ConformanceExecutable <path>` uses an already-built runner.
- `-NoBuild` skips `swift build` when an explicit/existing runner is used.
- `-ReportDirectory <path>` selects the JSON/Markdown output directory.
- `-AllowCorpusDrift` reports changed file counts without failing the gate.
- `-TimeoutSeconds <n>` limits each standalone source process.

By default reports go to the system temporary directory, keeping generated
GMod fingerprints and local paths out of Git.

## Corpus harness and SwiftPM tests

Copyright-safe unit fixtures, including Source KeyValues V1 and the GLua type
and bit surfaces, live in `GModEngineTests` and run with:

```powershell
swift test
```

The GMod corpus remains a separate script because its source files come from a
user-owned local installation and must not become SwiftPM resources. It reuses
the supported diagnostic product:

```powershell
swift build --product GModLuaConformance
```

On Windows, the package manifest excludes `GModApp` and `GModMetal`, where
SwiftUI and Metal are unavailable, while retaining `GModLua`, `GModEngine`,
the conformance executable, and `GModEngineTests`.

## Deferred gates are not passes

Every report explicitly emits:

- `[SKIP][BEHAVIOR]` for lifecycle/scenario assertions not yet executable.
- `[SKIP][RENDER]` for headless VGUI/render snapshots.
- `[SKIP][WORKSHOP]` for Workshop/GMA/mounted-addon behavior.

The declarative M1 contract in `manifest.json` records the expected registry
counts (network strings, cleanup categories, Spawnmenu registrations, and TTT
net entries) for later load/lifecycle runners. These values are not marked as
verified by this static per-file harness.
