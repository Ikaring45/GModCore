# GLua realm networking M3

M3 connects selected public GLua network contracts to explicit host-owned
state. It is designed for deterministic cross-realm testing and eventual iPad
host integration. It does not emulate Steam networking, Source snapshots,
player channels, prediction, or a live game server.

The implementation was derived from public API contracts and behavior probes.
The regression harness may read a legally installed Garry's Mod tree in place,
but this repository does not copy or redistribute its Lua source or assets.

## Shared NetworkString identity

`GMLuaNetworkedGlobalTransport` owns a single 4,095-entry name table shared by:

- legacy global-variable keys;
- SERVER `util.AddNetworkString` registrations;
- names passed to `net.Start`.

Identity is based on `LuaString` bytes, not lossy decoded Swift text. Invalid
UTF-8 byte sequences therefore remain distinct. Public string snapshots are
decoded for diagnostics only and are not used as internal identity.

IDs are stable, one-based, and visible through `util.NetworkStringToID` and
`util.NetworkIDToString`. `util.AddNetworkString` is installed only in SERVER.
Exhausting the shared slot limit is an explicit runtime error.

## Legacy network globals

The runtime implements the `SetGlobal*`/`GetGlobal*` families for bool, int,
float, string, Entity, Vector, and Angle values, plus the untyped
`SetGlobalVar`/`GetGlobalVar` aliases.

One key names one untyped cell: setting the same name through a different
typed setter replaces its value. Entity values cross realm boundaries as
network indices, while Vector and Angle values cross as copied Float32
components. No realm's Lua userdata is retained in the transport.

A SERVER runtime and its connected CLIENT runtimes see the same authoritative
server entries when constructed with the same transport. Client setters remain
local until a newer server revision is observed. Hosts can call
`resendServerSnapshot()` to reissue authoritative revisions and overwrite
conflicting client-local entries while leaving client-only keys intact.

The transport does not schedule the desktop engine's periodic resend. That
cadence must be driven by a future host network tick; claiming it automatically
would hide a missing integration layer.

## Bitstream and queued delivery

`GMLuaNetTransport` owns one logical SERVER endpoint and any number of CLIENT
endpoints. Supported operations currently include:

- `net.Start` and `net.Abort`;
- `net.WriteBit` / `net.ReadBit`;
- `net.WriteUInt` / `net.ReadUInt` for 1 through 32 bits;
- `net.WriteInt` / `net.ReadInt` for signed 1 through 32-bit values;
- `net.WriteFloat` / `net.ReadFloat` using IEEE 754 Float32 encoding;
- `net.WriteString` / `net.ReadString` with Lua byte-string preservation;
- `net.WriteData` / `net.ReadData` for explicitly bounded binary bytes;
- `net.ReadHeader`, `net.BytesWritten`, and `net.BytesLeft`;
- SERVER `net.Broadcast`.

The payload ceiling is 65,533 bytes. Unaligned bit writes are preserved, a new
`net.Start` discards an unsent writer, and completed packets are immutable.
Broadcast enqueues one packet per connected logical client and succeeds with
zero clients. It never invokes destination Lua during the sending call.

The host later calls `pump()` at a safe tick boundary. Delivery invokes the
destination realm's original Lua `net.Incoming` callback in deterministic
sequence order. Reader state is cleared even when the callback fails, and later
packets remain queued for a subsequent pump. Pumping is serialized so two host
threads cannot deliver the queue concurrently. `GMLuaRuntime.close()` detaches
its endpoint, removes packets involving that endpoint, and clears local
reader/writer state; this also allows a later SERVER runtime to attach to the
same transport.

## Presentation and host-input companions

The same milestone adds the small client-facing layers needed to continue the
measured TTT startup path:

- `chat.AddText` exists in CLIENT and emits immutable, ordered value
  snapshots for a future presentation adapter. It does not render a HUD.
- Engine-owned ConVars come from an explicit host catalog with case-insensitive
  identity, flags, bounds, help text, and live host updates. Unknown names
  remain absent.
- The logical `input` library reads host-provided bindings, key/button states,
  modifiers, cursor position, and key-trapping transitions. An untouched host
  reports no pressed controls and does not invent UIKit or keyboard events.
- A logical sound registry provides `sound.Add`, `sound.GetProperties`,
  `sound.GetTable`, `sound.Play`, global `Sound`, and the CHAN constants used by
  the corpus. It records immutable playback requests but has no audio backend.
- Native Panel layout invalidation tracks dirty, immediate, and deferred layout
  work. Logical Label controls retain text, font, foreground color, and
  alignment state without replacing the original Lua control.

Chat and input are not installed as synthetic SERVER APIs. Input is also
available to MENU as a host-fed local-device surface, while chat and all M3
network APIs preserve their narrower public realm gates. Engine ConVars remain
available in every realm when explicitly supplied by the host catalog.

## Measured startup evidence

The current strict SERVER TTT checkpoint completes the stages represented by
the same-state startup harness:

```text
Base
-> loose shared/server autorun
-> TTT
-> PostGamemodeLoaded
-> Initialize
-> InitPostEntity
```

The process exits 0, advancing beyond 0.1.43's first network-global blocker.
It still reports addon discovery, player connection, and engine entity
readiness as false/SKIP boundaries. Therefore the result means only that every
currently modeled stage completed; it does not mean TTT is playable or that a
desktop startup is complete.

The other final M3 startup gates report:

- strict CLIENT Sandbox modeled startup exits 0;
- strict MENU `lua/includes/init_menu.lua` completes 23 includes with zero
  gaps;
- strict CLIENT TTT performs 177 includes, with `cl_voice.lua` last, reaches
  `InitPostEntity`, then stops at `lua/vgui/DLabel.lua:127` when
  `self:GetSkin().Colours` is required. The default Derma skin and its
  `Colours` table have not yet been constructed.

The CLIENT TTT stop is the exact next compatibility boundary, not a PASS or a
classified skip. Addon discovery, CLIENT player connection, and live Entity
readiness remain false/SKIP inputs in all applicable modeled-startup results.

## Packaging validation

- Swift tests: 135/135 PASS;
- Engine complete strict-concurrency build: PASS;
- official Lua 5.1 suite: GC enabled, exit 0 through `final OK`, 38 chunk
  loads, two classified skips (`main.lua` CLI-only and `api.lua` C-API-only),
  88.39 seconds;
- installed corpus parser gate: 259/259;
- independent-file load diagnostic: 26/259.

The independent load gate intentionally withholds ordered shared bootstrap
state. Its result is diagnostic and is not a whole-corpus runtime PASS.

## Remaining network layers

- `net.Send`, targeted Player delivery, RecipientFilter, and a canonical
  server-side sender Player identity;
- a real connected `net.SendToServer` path;
- Vector, Angle, Entity, Table, Color, Matrix, and compressed-data codecs;
- NW/NW2, DataTable/DT, and NetworkVar entity replication;
- prediction, deltas, PVS/PAS, bandwidth limits, acknowledgements, and Source
  channel behavior;
- host tick integration for queued packet pumping and periodic global resends;
- CLIENT player connection and live engine entity readiness;
- default Derma skin construction and the remaining Panel/VGUI/Spawnmenu
  control surface;
- UIKit input/chat presentation, CoreText/Metal text rendering, platform audio,
  and iPad hardware validation.

## Public API references

- [`util.AddNetworkString`](https://wiki.facepunch.com/gmod/util.AddNetworkString)
- [`net.Start`](https://wiki.facepunch.com/gmod/net.Start)
- [`net.WriteBit`](https://wiki.facepunch.com/gmod/net.WriteBit)
- [`net.WriteUInt`](https://wiki.facepunch.com/gmod/net.WriteUInt)
- [`net.WriteInt`](https://wiki.facepunch.com/gmod/net.WriteInt)
- [`net.WriteFloat`](https://wiki.facepunch.com/gmod/net.WriteFloat)
- [`net.WriteString`](https://wiki.facepunch.com/gmod/net.WriteString)
- [`net.WriteData`](https://wiki.facepunch.com/gmod/net.WriteData)
- [`net.BytesWritten`](https://wiki.facepunch.com/gmod/net.BytesWritten)
- [`SetGlobalVar`](https://wiki.facepunch.com/gmod/Global.SetGlobalVar)
- [`GetGlobalVar`](https://wiki.facepunch.com/gmod/Global.GetGlobalVar)
- [`chat.AddText`](https://wiki.facepunch.com/gmod/chat.AddText)

M3 is a realm-networking substrate milestone, not a complete GMod networking
or GLua compatibility claim.
