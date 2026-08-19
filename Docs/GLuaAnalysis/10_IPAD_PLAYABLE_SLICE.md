# iPad playable slice boundary

This document records the post-0.1.45 integration boundary. It is an
engineering acceptance record, not a claim of complete Garry's Mod or Source
engine compatibility.

## Implemented vertical slice

- A host-owned paired Sandbox session contains one SERVER and one CLIENT on a
  serialized actor lane.
- The Source runtime adapter owns generation-safe world/player mirrors and
  separate SERVER fixed-tick, CLIENT fixed-tick, and CLIENT render-frame entry
  points.
- `gm_construct` and `gm_flatgrass` are bundled as manifest-locked BSP/NAV/AIN
  fixtures. BSP world brushes feed GLua `util.TraceLine`/`util.TraceHull`, the
  bounded player walk solver, and a coarse Metal world mesh.
- Original bundled Base, Sandbox, Derma, scripted-weapon, and Spawnmenu Lua is
  loaded. `OnGamemodeLoaded` creates the real `g_SpawnMenu`; the strict
  regression opens it and captures non-empty paint commands.
- Surface text, PNG/VMT/VTF material commands, pointer capture, stock DButton
  click ownership, popup/root docking, and point-space viewport mapping cross
  into the app/Metal boundary.
- The checked-in `Apps/GarrysPAD` iPadOS 16 application target presents
  `GModMainView`. Its CI definition hydrates and hashes Git LFS map payloads,
  builds the package libraries and app, launches an iPad Simulator, and runs
  the host/package tests.

## Content boundary

The bundle contains only explicitly selected project-authorized base content:

- 2,162 client-content files totaling 14,689,206 bytes;
- 1,698 material files totaling 12,369,996 bytes;
- a Source material closure of 72 VMT plus 46 VTF files totaling 3,013,414
  encoded bytes;
- 28 unique bundled font files, represented by 30 source aliases; and
- BSP/NAV/AIN files for `gm_construct` and `gm_flatgrass`.

Every entry is path/size/SHA-256 declared. The material verifier additionally
compares 117 files with `garrysmod_dir.vpk` and one file with
`platform_misc_dir.vpk`. Workshop, cache, and addon files are outside this
bundle. Addon material lookup is not considered Metal-renderable until GLua
and Metal share one session-scoped resolver.

## Windows acceptance evidence

On the final integration candidate snapshot:

- focused console/net/session/playable-session tests: 37/37 passed;
- full XCTest: 357 executed, one optional owned-MDL diagnostic skipped, zero
  failures;
- Swift Testing Source filesystem suite: 11/11 passed;
- the full run used installed `garrysmod_dir.vpk`, `platform_misc_dir.vpk`, and
  `gm_construct.bsp`, so the atlas/material/BSP diagnostics were not skipped;
- `GModEngine` and `GModGameSession` strict-concurrency builds with warnings as
  errors passed;
- the client-content verifier passed under PowerShell 7 and Windows PowerShell
  5.1; and
- Source Oracle ownership/mount safety tests passed 6/6 with zero remaining
  `gmod.exe` processes and zero Oracle mounts.

Windows cannot validate the Apple SDK, SwiftUI application semantics, Metal
shader/pipeline execution, Simulator launch, or real iPad touch/performance.
Those remain Apple CI and physical-device gates.

## Deliberate unsupported boundaries

- Spawnmenu opens and paints, but stock SpawnIcon prop creation is not
  supported. It reaches missing `Player:Alive`, model validation, `ents.Create`,
  entity/physics, undo, and cleanup APIs. Those calls must fail explicitly;
  they are not replaced with no-op success.
- World collision is brush-only. Displacements are coarse base faces, and
  step/jump/water/ladder/vphysics movement is unavailable.
- The current world renderer is coarse and does not yet render MDL/VVD/VTX
  model geometry, lightmaps, PVS, or complete material shader behavior.
- Addon discovery/mounting, Workshop, Steam/authentication, sockets, and live
  engine entity readiness are not part of the playable session.
- The current single-touch SwiftUI bridge cannot prove UIKit
  `touchesCancelled` parity; app inactive/background paths do issue an
  idempotent host cancellation and retire queued input epochs.

These boundaries are acceptance conditions: a later layer should connect to
the Source-compatible host contracts instead of weakening them with synthetic
success values.
