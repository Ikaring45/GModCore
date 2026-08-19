# GModCore

## Windows Lua 5.1 conformance runner

The pure Swift `GModLua` runtime can be built and tested without the iPad UI or
Metal renderer. On Windows with the official Swift toolchain installed, run:

```powershell
swift run GModLuaConformance
```

Individual Lua files and short diagnostic snippets can use the same native
runtime without launching Swift Playgrounds:

```powershell
swift run GModLuaConformance --file .\path\to\test.lua
swift run GModLuaConformance --eval 'print(table.getn({10, 20, 30}))'
```

The runner uses the same official-test order and Discovery classifications as
the iPad console. `main.lua`, unfinished `gc.lua`, and PUC C-API-only `api.lua`
are reported as skips rather than passes. A CORE failure returns a non-zero
process exit code.

An experimental C/C++ game engine compatibility project aimed at recreating a Garry's Mod / Source-like experience on iPad, with Swift Playgrounds used as the application shell.

> **Status:** Very early development.  
> The project currently contains only the initial native C/C++ core and Swift-compatible C API.

## Goal

The long-term goal of GModCore is to reproduce as much of the distinctive Garry's Mod experience as reasonably possible on iPad, including:

- Source-like player movement
- Physics-driven sandbox gameplay
- Props, entities and ragdolls
- Physgun and Toolgun-style interaction
- Constraints such as Weld, Rope, Axis and No-Collide
- Garry's Mod-style Lua / GLua compatibility
- Separate Server, Client and Menu Lua states
- Sandbox gamemode compatibility
- Spawnmenu and VGUI compatibility
- Source asset loading
- VPK and GMA addon support
- Local addon loading
- Keyboard, mouse, controller and touch input
- Metal-based rendering
- Fixed-timestep Source-like simulation
- Developer console, ConVars and ConCommands

The intention is not to create a simplified mobile sandbox inspired by GMod.

The objective is to build a compatibility-oriented engine that preserves as much of GMod's behavior, scripting model and distinctive Source-engine feel as possible.

## Architecture

Swift Playgrounds is used primarily as the iPad application host.

Most engine functionality is intended to live in native C/C++.

```text
Swift Playgrounds
│
├─ Application lifecycle
├─ iPad UI
├─ Files integration
├─ Touch input
├─ Keyboard / mouse / controller bridge
└─ Metal view host
        │
        ▼
      C ABI
        │
        ▼
     GModCore
       C/C++
│
├─ Engine
├─ Filesystem
├─ Console / ConVars
├─ Lua / GLua runtime
├─ Entity system
├─ Source-like movement
├─ Physics
├─ Renderer
├─ VPK / GMA loaders
├─ Source asset formats
└─ Addon compatibility
```

The Swift-to-engine boundary is intentionally kept small and uses a stable C ABI.

Example:

```c
typedef struct GMEngine GMEngine;

GMEngine *gm_create(void);
void gm_destroy(GMEngine *engine);
void gm_boot(GMEngine *engine);
```

Internally, the engine can use C++ freely without exposing C++ implementation details to Swift.

## Current State

The first milestone is establishing a working native C++ core that can be imported into a Swift Playgrounds application on iPad.

Current API:

```c
uint32_t gm_abi_version(void);

GMEngine *gm_create(void);
void gm_destroy(GMEngine *engine);
void gm_boot(GMEngine *engine);

const char *gm_version(void);

int32_t gm_test_add(
    int32_t a,
    int32_t b
);

void gm_set_log_callback(
    GMLogCallback callback
);
```

At this stage there is no renderer, physics system, Lua runtime or game world yet.

## Planned Development

Development will proceed incrementally.

### Phase 1 — Core

- Native C++ startup
- Logging
- Engine lifecycle
- Fixed-timestep clock
- Source-style console
- ConVars and ConCommands

### Phase 2 — Filesystem

- Virtual filesystem
- Source-style search paths
- KeyValues parser
- VPK reader
- GMA reader
- Addon mounting

### Phase 3 — Lua

- Lua 5.1-compatible runtime
- Server Lua state
- Client Lua state
- Menu Lua state
- `include`
- `require`
- hooks
- timers
- basic GLua types and APIs

### Phase 4 — World

- Entity system
- Map/world representation
- Player entity
- Collision and tracing
- Source-like movement
- Noclip

### Phase 5 — Rendering and Physics

- Metal renderer
- Source material support
- Source model support
- Physics backend
- Props
- Ragdolls
- Constraints
- Physgun

### Phase 6 — Garry's Mod Compatibility

- Base gamemode
- Sandbox gamemode
- Spawnmenu
- VGUI
- Toolgun
- SWEPs
- SENTs
- Dupes and saves
- Real-world addon compatibility testing

## Compatibility Research

Development is informed by publicly available Garry's Mod Lua code, public Source SDK code, official documentation and behavioral testing against a legitimate Garry's Mod installation.

Compatibility behavior is being reproduced independently.

## Legal / Project Scope

GModCore is an independent experimental project.

It is **not affiliated with, endorsed by, or sponsored by Facepunch Studios, Valve Corporation, or Garry Newman**.

Garry's Mod, Source, Steam and related names and trademarks belong to their respective owners.

This repository does not include Garry's Mod game assets, Valve game assets, proprietary engine binaries, leaked source code, or Workshop content.

Users are responsible for providing any legally obtained game content required for local compatibility testing.

## Platform

Primary target:

- iPadOS
- Swift Playgrounds
- ARM64
- Metal

The core is being designed in portable C/C++ where practical so that engine systems are not unnecessarily coupled to Swift or iPadOS.

## Why?

Garry's Mod has a very particular combination of:

- Source movement
- physics
- Lua scripting
- modding
- sandbox tools
- community-created content

That combination is difficult to replace with a generic mobile sandbox.

GModCore exists to investigate how much of that experience can be recreated natively on iPad while preserving the parts that make GMod feel like GMod.

---

**GModCore is currently a research and early-development project. Expect major architectural changes.**
