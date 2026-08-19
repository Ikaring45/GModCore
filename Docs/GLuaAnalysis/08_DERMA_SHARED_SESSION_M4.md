# Derma bootstrap and shared-session M4

M4 joins the client UI bootstrap and realm transport into one reproducible
startup path. It is deliberately a host/runtime milestone: it does not claim
platform backing/rendering for this new VGUI layer, a Steam session, or a
playable gamemode.

## Correct client-owned startup stages

The strict CLIENT orchestrator now executes these direct host stages in order:

```text
lua/includes/init.lua
lua/derma/init.lua
Base gamemode cl_init.lua
lua/autorun/*.lua
lua/autorun/client/*.lua
lua/postprocess/*.lua
lua/vgui/*.lua
lua/matproxy/*.lua
lua/skins/default.lua
target gamemode cl_init.lua
PostGamemodeLoaded
Initialize
logical player connection
InitPostEntity
```

The three special directories are non-recursive merged-VFS listings. Their
deterministic name order is a harness choice; only autorun's alphabetical
ordering is presented as the public engine contract. `lua/skins/default.lua`
is loaded as the exact required file rather than by enumerating arbitrary
skins.

MENU remains a separate realm order. Its `lua/includes/vgui_base.lua` stage is
not reused as a CLIENT shortcut. SERVER has no Derma, VGUI, or skin stage.

## Default skin without copied assets

`GMLuaVPKArchive` reads VPK v1/v2 directory entries and payload sections,
validates bounds and entry CRC values, and canonicalizes material paths. VPK
v2 archive-MD5 and signature sections are not authenticated. The release
contains no installed VPK or extracted image.

`GMLuaVPKMaterialPixelResolver` resolves the installed
`materials/gwenskin/GModDefault.png` at runtime. Decoded rasters are cached and
expose top-left RGBA pixels through a platform-neutral contract:

- Windows uses WIC;
- Apple uses ImageIO/CoreGraphics and converts premultiplied pixels back to the
  straight-RGBA contract;
- unsupported hosts fail explicitly.

The original Default skin therefore receives real `Color` values from
`IMaterial:GetColor`. Missing resolver data does not silently become a hard-
coded palette or a fabricated white texture.

The same resource layer supplies the minimal logical `IMaterial` and
`ITexture` operations required by load-time post-processing and skin code.
General VMT/VTF material resolution, shader execution, GPU texture allocation,
and draw submission are not implied.

## Shared SERVER/CLIENT session

`GMLuaSharedSession` owns one `GMLuaNetTransport` and connects an already
started SERVER to one or more CLIENT runtimes. A connection has explicit
EntIndex, UserID, and generation identity.

The session provides:

- Player mirrors in SERVER and every connected CLIENT, with realm-local
  userdata and Lua tables;
- `LocalPlayer()` identity in each CLIENT;
- CLIENT `net.SendToServer` with the canonical SERVER-side Player sender;
- SERVER targeted `net.Send(Player)` and broadcast delivery;
- forwarded CLIENT console commands using the SERVER's normal ownership order:
  Lua ConVar, engine host handler, then registered Lua concommand;
- one deterministic FIFO covering net and console events;
- explicit `pump()` delivery outside the sending Lua call;
- generation-aware disconnect and queued-event cleanup;
- serialized connect, disconnect, pump, and runtime close lifecycle boundaries.

The host starts SERVER first so its NetworkString registrations exist before
CLIENT target startup. CLIENT connection occurs after `Initialize` and before
`InitPostEntity`, matching the boundary required by the measured TTT path.

## Entity Lua tables

Each live Entity-family value owns a realm-local and generation-local Lua
sidecar table. The compatibility rules are:

- repeated `GetTable()` returns the same table identity;
- `SetTable(table)` installs that exact table without copying it;
- metatable methods take precedence over same-named sidecar fields;
- arbitrary Entity-family field assignment uses ordinary table assignment
  semantics;
- NULL and stale userdata return no sidecar and silently drop arbitrary writes;
- reconnecting or reusing an EntIndex creates fresh userdata and a fresh table;
- host GC roots retain live canonical userdata and sidecars even if scripts
  overwrite the usual global lookup functions.

`Player(number)` is a UserID lookup. It is intentionally separate from
`Entity(number)`, which uses EntIndex. `LocalPlayer()`, `Entity(EntIndex)`, and
`Player(UserID)` resolve to the same canonical userdata inside one connected
CLIENT realm.

These rules were compared with an authenticated local Garry's Mod oracle. The
probe confirmed sidecar identity, method precedence, exact SetTable identity,
custom table metamethods, debug-environment separation, realm isolation,
removed-entity NULL behavior, and fresh state after EntIndex reuse. The probe
and its results were deleted after collection.

## Logical VGUI corrections

The M4 logical VGUI layer also corrects behavior exercised by the startup and
synthetic regressions:

- exact DOCK numeric ABI and ascending-Z docking order;
- alpha-zero panels retain layout space;
- root `Center()` uses the current logical viewport;
- ancestor alpha is composed for child draw commands;
- three-component draw/text colors default alpha to 255;
- global `DisableClipping` is available;
- a `Paint` return value of true suppresses the logical default Label/image;
- host pointer routing invokes mouse hooks but does not duplicate scripted
  `DoClick` or `DoDoubleClick` calls;
- native text insertion emits `OnTextChanged` once and leaves
  `OnValueChange` policy to the original Lua control.

This is renderer-neutral command/state behavior. UIKit/Metal views, hit-test
delivery, original DButton capture/hover/drag semantics, and full layout or
paint parity are not yet present.

## Measured results and boundaries

The strict paired runner completes Sandbox and TTT through both realms'
`InitPostEntity`. The TTT run delivers four queued net/console events. These
results mean the represented startup stages completed; they do not mean that
players can join a live server or play a round.

The runner still reports addon loading, Steam authentication, and engine
entity readiness as false/SKIP. It does not dispatch the engine's complete
desktop startup or instantiate Spawnmenu through `OnGamemodeLoaded`.

VPK/image parsing currently assumes trusted installed content. Allocation and
decompression budgets for hostile Workshop archives are a required future
hardening layer, and VPK v2 archive-MD5/signature authentication is not yet
implemented. No GMod Lua source, game asset, VPK payload, or proprietary engine
binary is included in this repository.
