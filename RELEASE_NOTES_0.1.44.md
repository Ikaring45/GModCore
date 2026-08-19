# Garry's PAD / GModCore 0.1.44

## Realm networking M3

This milestone introduces a host-owned realm transport instead of treating
network-facing GLua calls as unrelated state-local placeholders. It also adds
the chat, input, engine-ConVar, logical sound, and VGUI control substrates
required by the measured client startup paths.

The implementation is intentionally narrower than Source networking. It makes
the supported contracts deterministic and testable without claiming player
connections, prediction, snapshots, or a complete `net` library.

Highlights:

- one shared, byte-preserving 4,095-slot NetworkString pool for global keys,
  `util.AddNetworkString`, and net-message names;
- host-shareable `SetGlobal*`/`GetGlobal*` storage for bool, number, string,
  Entity identity, Vector, and Angle values, including `SetGlobalVar` and
  `GetGlobalVar` aliases;
- explicit server-snapshot resend support, while leaving scheduling to the
  host rather than fabricating the desktop engine's periodic cadence;
- a deterministic one-SERVER/many-CLIENT net session with immutable queued
  packets and an explicit host `pump()` boundary;
- serialized packet pumping plus explicit endpoint detach/queue cleanup when a
  runtime closes, allowing a later SERVER runtime to own the session cleanly;
- bit-accurate `Start`, `Abort`, bit/unsigned/signed integer, Float32, string,
  and binary-data codecs plus read cursors and message-size accounting;
- SERVER `Broadcast` delivery to connected logical clients, including safe
  zero-client completion without send-time Lua re-entry;
- CLIENT `chat.AddText` capture as immutable presentation events without
  claiming a rendered chat HUD;
- a host-populated engine-ConVar catalog that keeps unknown engine values
  absent instead of inventing Source configuration;
- a host-fed CLIENT/MENU input substrate for bindings, key/button state,
  cursor position, modifier queries, and key trapping without fabricating
  physical input;
- a logical named-sound registry with `sound.Add`, property/table lookup,
  playback-event capture, the global `Sound` helper, and CHAN constants,
  without claiming platform audio output;
- native `Panel:InvalidateLayout` dirty/deferred layout state and logical Label
  text, font, foreground color, and alignment controls, without replacing the
  original Lua controls or claiming rendered text.

The installed-GMod strict SERVER TTT modeled startup now completes every stage
currently represented by the harness: Base, loose shared/server autorun, TTT,
`PostGamemodeLoaded`, `Initialize`, and `InitPostEntity`. This is an advance
from the 0.1.43 `SetGlobalFloat` blocker, not a claim that TTT is playable.

## Validation state

The final 0.1.44 packaging validation reports:

- 135/135 Swift tests pass;
- the Engine target passes complete strict-concurrency checking;
- the official Lua 5.1 basic suite runs with GC enabled, exits 0 through
  `final OK`, performs 38 chunk loads, and completes in 88.39 seconds;
- its only two classified skips remain `main.lua` (CLI-only) and `api.lua`
  (PUC C-API-only);
- the installed-tree parser gate passes 259/259 files, while the deliberately
  independent-file load diagnostic reaches 26/259;
- strict SERVER TTT modeled startup exits 0 through `InitPostEntity`;
- strict CLIENT Sandbox modeled startup exits 0;
- the realm-correct strict MENU `init_menu.lua` gate completes 23 includes
  with zero gaps;
- strict CLIENT TTT performs 177 includes, with `cl_voice.lua` last, reaches
  `InitPostEntity`, and then stops at `lua/vgui/DLabel.lua:127` because the
  default Derma skin and its `Colours` table have not yet been constructed.

The parser and independent-load measurements are diagnostics with different
state contracts; neither is presented as proof that every engine API used by
the corpus is implemented.

## Honest boundaries

This release is not a complete GMod network or gameplay runtime.

- `net.Send` and a real `net.SendToServer` player/session path are not
  implemented. The current client call fails explicitly when disconnected or
  when no canonical server-side Player endpoint exists.
- SERVER broadcast is the implemented send path. Recipient filters, targeted
  Player delivery, full codecs such as Vector/Angle/Entity/Table/Color, and
  Source bandwidth/rate behavior remain later work.
- Packet delivery occurs only when the host calls `pump()`. It is not attached
  to a live iPad client/server tick connection yet.
- `resendServerSnapshot()` is explicit. The desktop engine's documented
  periodic global-value resend is not automatically scheduled.
- Client-local global writes and later authoritative server resends are
  modeled, but NW/DT/NetworkVar entity state, prediction, deltas, and PVS
  behavior are not.
- `chat.AddText` records presentation-neutral events; it does not draw a chat
  HUD. Logical input is host-fed; UIKit keyboard, touch, controller, and cursor
  adapters are not connected by this milestone.
- The sound registry records logical definitions and playback requests; no
  platform audio backend is connected. Label state and layout invalidation
  have no UIKit/CoreText/Metal text or view backing.
- CLIENT TTT's exact next blocker is construction of the default Derma skin
  and its `Colours` table. The stop is not classified as a pass or skipped.
- Engine ConVars exist only when supplied by the host catalog. Persistence,
  replication, and a complete engine-owned catalog remain incomplete.
- Addon/GMA/VPK discovery, CLIENT player connection, and live engine entity
  readiness are still false/SKIP boundaries in modeled startup. Physics,
  Source assets, Workshop, and complete Entity/Panel behavior remain outside
  this result.
- The shared runtime is verified quickly on Windows. New host paths still need
  Swift Playgrounds/iPad hardware validation; a Windows pass is not presented
  as an iPad build or device result.

## Public contract references

The implementation is based on the public Facepunch API descriptions for
[`util.AddNetworkString`](https://wiki.facepunch.com/gmod/util.AddNetworkString),
[`net.Start`](https://wiki.facepunch.com/gmod/net.Start),
[`net.WriteBit`](https://wiki.facepunch.com/gmod/net.WriteBit),
[`net.WriteUInt`](https://wiki.facepunch.com/gmod/net.WriteUInt),
[`net.WriteInt`](https://wiki.facepunch.com/gmod/net.WriteInt),
[`net.WriteFloat`](https://wiki.facepunch.com/gmod/net.WriteFloat),
[`net.WriteString`](https://wiki.facepunch.com/gmod/net.WriteString),
[`net.WriteData`](https://wiki.facepunch.com/gmod/net.WriteData),
[`SetGlobalVar`](https://wiki.facepunch.com/gmod/Global.SetGlobalVar),
[`GetGlobalVar`](https://wiki.facepunch.com/gmod/Global.GetGlobalVar), and
[`chat.AddText`](https://wiki.facepunch.com/gmod/chat.AddText).

No Garry's Mod Lua corpus, proprietary game asset, or proprietary engine
binary is included in this release.
