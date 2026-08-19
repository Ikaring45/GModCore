# GLua Gameplay Bootstrap M1 implementation

This milestone converts the static bootstrap/corpus analysis into an
executable, copyright-safe runtime gate. It reads an installed Garry's Mod
tree in place and does not copy or redistribute Valve or Facepunch Lua source.

## Production and discovery are separate

`GMLuaRuntime` defaults to `GMLuaBootstrapMode.strict`. Strict mode contains
only implemented behavior; an unavailable engine API raises at its first use.
It is the production compatibility result.

`GMLuaBootstrapMode.discovery` adds diagnostic-only objects that allow the
loader to expose later dependencies. Every scaffold marks a named
`compatibilityGap` when it is actually used. The corpus harness records a
successful discovery execution with one or more gaps as
`[SKIP][DISCOVERY]`, with `loadPassed=false`. Discovery therefore cannot turn
an unfinished API into a compatibility PASS.

Current discovery scaffolds cover placeholder Vector/Angle, Entity/Panel,
ConVar, Material, the non-persistent SQL surface, and a surface texture ID
sentinel. Render APIs are deliberately not scaffolded: a client bootstrap
must stop until the Metal-backed resource contract exists.

## Implemented M1 substrate

### Realms

- SERVER: `SERVER=true`, `CLIENT=false`, `MENU=false`.
- CLIENT: `SERVER=false`, `CLIENT=true`, `MENU=false`.
- MENU: `SERVER=false`, `CLIENT=true`, `MENU=true`, `MENU_DLL=true`.

MENU deliberately exposes the client-side branch. Treating it as a third
mutually exclusive state caused GMod module code to enter server-only paths.

### Mounted, sandboxed VFS

`GMLuaMountedFileSystem` resolves prioritized virtual roots onto host roots
and supports a separate writable overlay. `GMLuaHostDirectoryFileSystem`
rejects traversal outside its configured root.

Every host path component first uses an exact match and then a deterministic,
case-insensitive directory lookup. This makes iPad's case-sensitive storage
behave like the Windows-authored GMod corpus without relying on Windows to
hide case mismatches. The self-test uses a mixed-case `IconEditor.lua`
fixture and requests it with different casing.

### Lua loading primitives

- `include(path)` searches relative to the calling source before the global
  `lua/` root, preserves the virtual source name, inherits the caller's
  environment, and returns all values from the included chunk.
- Nested includes resolve from the nested chunk rather than the original
  entry point.
- Server `AddCSLuaFile(path)` records the resolved logical path; the no-arg
  form records the current source.
- GMod module lookup prepends `lua/includes/modules/?.lua`, `lua/?.lua`, and
  `lua/?/init.lua` to `package.path`.
- The LuaJIT BitOp-compatible `bit` table is installed in every normal GMod
  runtime and exposed through the same object at `package.loaded.bit`.
- Runtime diagnostics and registries expose included files, client files,
  console commands, network strings, and used discovery gaps.

### Source KeyValues V1

`SourceKeyValuesParser` is a native Swift parser rather than a success stub.
It supports quoted and bare tokens, nested braces, `//` comments, optional
escape processing, case preservation, ordered entries, duplicate keys, and
conditional-token preservation for the preserve-order form.

Normal `util.KeyValuesToTable` conversion unwraps a single root object,
converts numeric-looking keys to numeric Lua keys, and applies last-value-wins
semantics for duplicate keys. `util.KeyValuesToTablePreserveOrder` retains
duplicates as `{ Key, Value, Conditional }` entries.

The regression runner parses the installed `settings/users.txt` (407 bytes in
the measured installation). Server discovery also reaches the real
player-auth users-file path while loading `init.lua`.

The repository also contains an original, redistributable KeyValues fixture
and four XCTest cases covering comments, quoted/bare tokens, nested objects,
escapes enabled and disabled, duplicate last-wins conversion, case
preservation, conditional/order preservation, and malformed-input errors.

Runtime bootstrap installation failures, including a failure to install the
bit module, are retained by the non-throwing initializer and rethrown by the
first `execute`, `executeReturningValues`, or `loadFile` call. A partial
bootstrap can therefore never degrade into an unrelated missing-global error.

## Measured bootstrap state

Measured on the local 2026-08-19 Garry's Mod install with the Windows
conformance executable built from the same Swift sources:

| Entry | Mode | Result | Includes | Exact next blocker |
|---|---|---:|---:|---|
| `lua/includes/init.lua`, SERVER | strict | load fail | 2 | `lua/includes/util.lua:240`, global `Vector` is nil |
| `lua/includes/init.lua`, SERVER | discovery | discovery-only completion | 27 | 5 used compatibility gaps; never a production PASS |
| `lua/includes/init.lua`, CLIENT | discovery | load fail | 6 | `lua/includes/modules/halo.lua:7`, global `render` is nil |
| `lua/includes/init.lua`, MENU | discovery | load fail | 6 | `lua/includes/modules/halo.lua:7`, global `render` is nil |

The final strict corpus gate parses 259/259 files and loads 21/259. The load
count is intentionally low: missing GLua/engine APIs remain classified
blockers instead of being silently stubbed.

## Verification commands

```powershell
swift test --scratch-path .build-glua-m1

swift build --product GModLuaConformance --scratch-path .build-glua-m1

./.build-glua-m1/x86_64-unknown-windows-msvc/debug/GModLuaConformance.exe `
  --gmod-bootstrap-selftest

./.build-glua-m1/x86_64-unknown-windows-msvc/debug/GModLuaConformance.exe `
  --keyvalues-file "C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\settings\users.txt"

./Tests/GModCorpus/run_m1_corpus.ps1 `
  -GModRoot "C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod" `
  -RuntimeMode gmod -Gate parse
```

## Remaining honest blockers

- Native Vector/Angle constructors and operations, plus complete
  Entity/Player/Panel registries and methods.
- Metal-backed Material, surface, render, texture, and render-target APIs.
- Persistent SQLite behavior for `sql.*`.
- Full GMod file search/mount semantics, including directory enumeration.
- KeyValues directives/inheritance and evaluation of platform conditionals.
- Gamemode lifecycle, VGUI/Spawnmenu behavior, networking, assets, and
  Workshop/GMA mounts.

The next production bootstrap step is to replace the strict SERVER `Vector`
blocker with a real value type. CLIENT/MENU should keep the `render` blocker
until the Metal resource layer can supply actual screen-effect textures.
