# VGUI runtime follow-up (unreleased)

- Separate ordinary self-invalidation from the same-frame child-extent/docking
  worklist. Stock RopeMaterial previously exhausted the 64-pass guard at the
  1024 x 768 viewport; its four-frame regression now completes.
- Provide CLIENT gui.ScreenToVector from the live viewport, player view angles
  and world horizontal FOV, returning a normalized canonical Vector.
- Add BOX direction constants and native popup modal ownership/IsModal state.
- Root the canonical NULL captured by native entity methods across Lua GC.
- Expose IMaterial:GetString for the retained base-texture metadata only.
  Arbitrary VMT string parameters remain unsupported; CreateMaterial is still
  missing, so the complete stock DImage VertexLit/Cable conversion is not done.

Validation: Windows portable build; 59 VGUI registry tests and the stock Rope
regression pass after the layout fix. Separate screen-ray, captured-NULL and
base-texture tests passed during this work. These do not prove iPad latency,
Metal rendering, all Hint userdata failures, or complete modal input parity.
The reported users.txt startup message and stuckRecovery are not fixed here.

## Post-0.1.67 Hint fix (unreleased)

Physical-device logs still reported util.lua:318 from Hint timers. A new test
reproduced that exact error with collectgarbage followed by stock
notification.AddLegacy. The engine-owned OverlayPanel was absent from the VGUI
GC reference list (only WorldPanel was included). Rooting the overlay userdata
and its instance table makes the four-collection/notification/render regression
pass on Windows. Physical iPad confirmation remains outstanding. CreateMaterial
and the reported c_arms empty-geometry rejection are still separate open issues.

## DImage CreateMaterial slice (unreleased)

CreateMaterial now supports the stock DImage conversion: UnlitGeneric with an
already resolved base texture and enabled vertexcolor/vertexalpha. Generated
name identity, Material("!name"), shader/string queries, source import settings,
dimensions and Surface bitmap selection are connected. All nine resource-handle
tests pass on Windows, including a generated-material panel Paint capture.
Unsupported shaders,
proxies, other parameters and unresolved source textures explicitly fail; this
is not a complete runtime VMT/shader implementation. The original DImage Lua is
unchanged. Reference: https://wiki.facepunch.com/gmod/Global.CreateMaterial

The c_arms path is authored directly by stock weapon_fists as its ViewModel,
with UseHands enabled. It is not a mistyped replacement for c_arms_citizen.
Its empty-resource rejection remains open: determine whether the loaded resource
is animation-only and how it should interact with the separate hands-rendering
integration. No substitute geometry was added.

## Empty ViewModel publication (unreleased)

A fully empty decoded ViewModel now publishes unavailableEmptyGeometry and a
nil projection before Metal conversion. The App logs the authored model and
the missing hands integration explicitly rather than treating it as a complete
rendering fix. This clears a previously displayed weapon and permits recovery
on the next drawable weapon. Partially malformed geometry is not admitted;
Metal's existing validation remains unchanged. Six portable ViewModel projection
tests pass, including visible -> empty -> visible transitions. App/Metal and
physical-iPad verification remain outstanding.

## First-person composite handoff (unreleased)

SWEP render definitions now retain inherited UseHands with Lua truthiness.
The session/lane exposes a single CLIENT first-person frame containing the
replication cursor, full-handle active weapon, SWEP definition, viewmodel and
conditionally enabled hands publication. Disabled hands produce nil even if
their canonical entity remains alive. Closed/stale lanes cannot publish frames.
This is renderer handoff data, not finished App/Metal hands rendering: bone
merge, weapon animation pose and the actual additional draw remain unconnected.
Four Windows tests pass, including active-weapon identity, live UseHands off/on
and refusing a frame after lane close. No App/Metal or physical-device pass is
claimed by these tests.

## Named-bone following and CPU skinning (unreleased)

Added an independent Source-style named-bone merge step. ASCII case-insensitive
names select followed transforms; the owner's bone mask gates copying.
Unmatched descendants use their actual local pose under the resulting parent.
Transform counts, hierarchy, ambiguous names and non-finite matrices fail
explicitly. Caller-provided followed matrices must share the owner's space.

The existing animated Studio compiler accepts this input before computing
bone-to-model * poseToBone and weighted position/normal/tangent skinning.
Ten portable tests pass, including reordered/case-varied names, masks,
unmatched descendants, malformed palettes, and a decoded two-bone fixture whose
weighted vertices actually change after following. This is not Windows Oracle
or real-asset/iPad parity proof. The live hands animation/cache and App/Metal
additional draw are still unconnected; IK and procedural bones are not added.

Contract references (read for behavior; not source-code transplantation):
- https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/client/bone_merge_cache.cpp
- https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/public/bone_setup.cpp
