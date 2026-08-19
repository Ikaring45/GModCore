# Garry's PAD / GModCore 0.1.45

## Derma bootstrap and paired-realm M4

This milestone replaces two major standalone-runtime shortcuts with explicit,
host-owned compatibility layers.

First, CLIENT startup now follows the measured installed-engine order through
Derma, post-processing, the VGUI and material-proxy directories, and the
Default skin. The skin samples the real `GModDefault.png` from a legally
installed VPK through a platform image decoder. No Garry's Mod asset, palette,
or Lua corpus is copied into this repository or release archive.

Second, SERVER and CLIENT runtimes can now join one deterministic shared
session. The session supplies canonical Player mirrors, client-to-server and
targeted server-to-client net delivery, forwarded console commands, and
per-Entity Lua storage. This is enough for paired strict Sandbox and TTT to
complete every startup stage currently modeled by the harness.

Highlights:

- corrected CLIENT host order:
  `init -> derma -> Base -> autorun -> postprocess -> vgui -> matproxy ->`
  `Default skin -> target gamemode -> lifecycle`;
- read-only VPK v1/v2 lookup with CRC checking, path canonicalization, and
  cached PNG decoding through WIC on Windows and ImageIO/CoreGraphics on Apple;
- resolver-backed `IMaterial`/`ITexture` dimensions and pixel colors, plus the
  logical material and render-target operations needed by the measured
  bootstrap path;
- a one-SERVER/many-CLIENT shared session using one NetworkString pool and one
  deterministic FIFO for net packets and forwarded console commands;
- `net.SendToServer`, targeted `net.Send`, canonical server-side sender Player,
  explicit host pumping, connection generations, disconnect cleanup, and
  close/connect lifecycle serialization;
- Player identity separated correctly: `Entity(number)` uses EntIndex while
  `Player(number)` uses UserID, and `LocalPlayer()` aliases the connected
  CLIENT's canonical Player;
- realm-local, generation-local Entity Lua tables with exact `GetTable` and
  `SetTable` identity, method-before-sidecar lookup, ordinary `__newindex`,
  stale/NULL write dropping, and explicit GC roots;
- logical VGUI improvements for the measured UI path: exact DOCK constants,
  ZPos-aware docking, viewport-aware root centering, cumulative alpha,
  paint-return suppression, color defaults, clipping state, and corrected
  text/pointer callback dispatch.

The Entity behavior was checked against an authenticated local Garry's Mod
oracle run. Temporary Entity-oracle probe files and results were removed after
capture; no probe or installed-game content is included in the tracked release
archive.

## Validation state

The exact release-candidate validation reports:

- 170/170 Swift tests pass from a clean checkout, with the installed-VPK
  Default-atlas diagnostic executed rather than skipped;
- the Engine target passes complete strict-concurrency checking with warnings
  treated as errors;
- the official Lua 5.1 basic suite runs with GC enabled and exits 0 through
  `final OK` in 92.84 seconds, with 38 chunk loads and only the two existing
  CLI/C-API classifications;
- the installed-tree parser gate passes all 259 targeted files;
- strict paired SERVER/CLIENT Sandbox exits 0 through both realms'
  `InitPostEntity` dispatch;
- strict paired SERVER/CLIENT TTT exits 0 through both realms'
  `InitPostEntity` dispatch and delivers four queued cross-realm events;
- strict standalone SERVER Sandbox and TTT remain passing checkpoints;
- the bootstrap self-test and release archive hygiene checks pass.

Exact test counts and elapsed timings are recorded in the accompanying
compatibility status document from the same release commit. Parser, isolated
load, ordered startup, and paired-session measurements remain distinct gates;
none is substituted for another.

## Honest boundaries

This is a startup/runtime compatibility milestone, not a playable GMod port.

- The paired runner supplies a deterministic logical player connection. Steam
  authentication, real sockets, Source net channels, prediction, PVS/PAS,
  snapshots, acknowledgements, and bandwidth behavior are not implemented.
- Packet and remote-console delivery still occurs only when the host calls
  `pump()`. The desktop engine tick cadence and periodic global-value resend
  are not fabricated.
- Addon/GMA discovery and engine entity readiness remain false/SKIP boundaries.
  `OnGamemodeLoaded` Spawnmenu instantiation is not dispatched by this runner;
  loading and registering its Lua files is not a claim that the menu is live.
- VPK and image paths are intended for trusted, legally installed content in
  this milestone. Practical allocation/decompression budgets required before
  accepting untrusted Workshop archives are not yet enforced. Entry CRC32 is
  checked, but VPK v2 archive-MD5 and signature sections are not authenticated.
- The Default Derma atlas is decoded and sampled, but general VMT/VTF material
  resolution and full Spawnmenu rendering are not complete. An unresolved
  material does not become a fabricated white or error-free placeholder.
- The new VGUI, Surface, chat, input, sound, and render commands remain logical
  host state. This layer is not connected to the existing app/Metal platform
  view or draw backend, and has no UIKit/CoreText input, text, or audio bridge.
  Original DButton mouse behavior still needs the remaining hover, capture,
  enabled, and drag/drop engine substrate.
- `Panel:NoClipping`, full docking/layout/paint parity, physics, BSP/MDL
  gameplay integration, and Workshop mounting remain later work.
- Swift Apple-facing sources are syntax/parse checked. The new C++
  ImageIO/CoreGraphics branch is not built or linked on Apple here, and no iPad
  hardware run was performed. A Windows pass is not reported as device proof.

## Public contract references

The compatibility behavior follows the public Facepunch contracts for
[`Entity:GetTable`](https://wiki.facepunch.com/gmod/Entity%3AGetTable),
[`Entity:SetTable`](https://wiki.facepunch.com/gmod/Entity%3ASetTable),
[`net.SendToServer`](https://wiki.facepunch.com/gmod/net.SendToServer),
[`net.Send`](https://wiki.facepunch.com/gmod/net.Send),
[`Panel:SetZPos`](https://wiki.facepunch.com/gmod/Panel%3ASetZPos), and
[`PANEL:Paint`](https://wiki.facepunch.com/gmod/PANEL%3APaint).

GModCore remains independent research and is not affiliated with or endorsed
by Facepunch Studios or Valve Corporation.
