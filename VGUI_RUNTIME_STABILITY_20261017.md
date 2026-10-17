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

## Two-model animation resource and preparation cache (unreleased)

Prepared assets can now snapshotFollowing another decoded Studio asset with
explicit owner/followed sequence, blend and integer frame selections. Followed
pose evaluation does not compile its vertices, so an animation-driving model
with empty geometry can drive a drawable owner. The merged resource identity
includes both complete appearance/frame identities and the bone mask; it is
not interchangeable with an owner-only animated resource.

The production animation cache resolves both preparations through its existing
bounded repository path. It retains decoded assets, not an unbounded cache of
merged frame vertices. Owner/followed asset failures remain distinguishable.
Fifteen portable tests pass, covering empty followed geometry, actual skinned
vertices, changing parent-frame identity, thirty-frame stable cache retention,
invalid parent sequences/paths, and preservation of the owner's original pose.
These fixture results do not prove c_arms asset parity or physical iPad output.
Live sequence/cycle selection, session requests and the additional Metal draw
remain outstanding. Apple CI for the preceding 695b49d was observed running;
no Apple pass is claimed for this change.

## Asset-backed ViewModel sequence lookup (unreleased)

LookupSequence no longer unconditionally returns -1: the session installs a
bounded decoded-MDL sequence resolver for SERVER and CLIENT. Exact name/index
lookups return the authored index and single-blend duration; multi-blend timing
remains explicitly unsupported rather than selecting a guessed pose parameter.
Missing assets/sequences return the invalid result (-1, 0).

SendViewModelMatchingSequence records the decoded sequence name and duration in
the canonical Weapon runtime snapshot and therefore uses the existing SERVER
journal/FIFO. CLIENT ViewModel read methods now resolve full handles against
CLIENT snapshots rather than the absent SERVER mutation host. Mutations remain
SERVER-only. Successful runtime close releases the sequence resolver/cache.

This does not yet select SendWeaponAnim activities, advance cycle/start time,
or submit live bone-merged hands to Metal. Those remain completion requirements.
Reference: https://wiki.facepunch.com/gmod/Entity:LookupSequence

Validation: three Windows tests pass: decoded MDL name/index/timing (including
zero FPS and unsupported multi-blend), SERVER Lua lookup/selection followed by
CLIENT FIFO reads with no direct mirror, and original weapon_base reload.
CLIENT mutation rejection and resolver cleanup after close are also asserted.
Apple, Oracle and physical-device behavior remain unverified for this change.

## Canonical fixed-tick ViewModel cycle (unreleased)

Decoded sequence metadata now carries frame count, looping and the authored
single-blend cycle rate. Weapon runtime snapshots retain cycle and the last
simulation-time advance. Named sequence selection resets the cycle; playback
rate changes preserve progress up to the exact mutation boundary.

After SERVER Think and before FIFO draining, the session advances only active
canonical weapons. CLIENT GetCycle and the first-person frame consume these
replicated values rather than advancing another authoritative clock. The value
clock validates time/state transactionally, caps elapsed time at 0.2 seconds,
defers intervals <= 0.001, wraps looping cycles and clamps non-looping ends.
Unknown sequence timing remains stationary rather than using a guessed speed.

The packet retains fractional cycle and decoded frame count; it does not round
to an integer frame and claim Source interpolation. Fractional pose sampling,
activity selection via SendWeaponAnim, animation events, and the live additional
Metal hands draw remain outstanding.
Reference: Valve baseanimating.cpp StudioFrameAdvance/StudioFrameAdvanceInternal.
https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/baseanimating.cpp

Validation: six Windows tests pass: pure clock wrap/end/pause/interval guards,
live session GetCycle and replicated frame metadata, pause/resume/restart,
existing active Toolgun projection, and original weapon_base reload. Apple,
Oracle and actual iPad output remain unverified. No interpolated animated-draw
success is claimed.

## Inline Studio RLE position channels (unreleased)

ANIMPOS channels now retain shared immutable MDL storage and sample signed
16-bit RLE values at exact integer frames. Axis pointers are signed offsets
relative to the value-pointer table; non-positive offsets mean no axis data.
Sampling repeats the last valid value within a run, advances between runs,
and applies the decoded bone position scale and non-delta bind position.
Invalid zero/oversized run headers, truncated samples and non-finite scaled
positions fail explicitly. Storage is not expanded by frame count.

This extends the existing pose evaluator used by animated mesh compilation;
it does not yet supply fractional pose interpolation, compressed rotations,
external animation blocks, sections, IK, or live Metal animation playback.
Reference: Valve studio.h mstudioanim_valueptr_t and bone_setup.cpp
ExtractAnimValue/CalcBonePosition (independent implementation).
https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/public/bone_setup.cpp

Validation: 18 Windows animation and animated-renderable tests passed, including
RLE run boundaries/repeats, signed negative samples, absent axes, malformed and
truncated runs, and changed weighted vertices with preserved normals, indices
and material draw ranges. Apple, Oracle and physical iPad output remain unverified.

## Subframe position evaluation and immutable geometry identity (unreleased)

Inline RLE positions now support a validated fractional frame. Sampling uses
the Source >0.001 interpolation threshold, scales signed values before blending,
crosses RLE run boundaries, and honors the paired extractor's initial 1/1 constant
axis rule. Local positions are evaluated before rebuilding the bone hierarchy;
model-space matrices are not linearly interpolated. Final-frame overshoot and
non-finite/out-of-range fractions fail explicitly.

The fraction survives prepared snapshot compilation, owner/followed bone-merge
selection, GameSession resource keys, the App adapter's consistency checks, and
Metal geometry identity/diagnostic keys. A replicated first-person frame can
derive a frame plus fraction from its authoritative cycle and authored frame
count without a second clock or integer rounding.

Compressed rotations, activity selection, animation events, sections/external
blocks, and live first-person Metal playback remain incomplete; this change is
not evidence of physical iPad rendering parity.

Validation: 26 Windows animation/cache tests passed, including fractional
weighted positions, hierarchy, threshold/constant-axis behavior, owner/followed
identity and cycle conversion. Apple-only geometry identity has an added test
but is not covered by that Windows result.

The original GLua sequence selection / SERVER fixed-clock / CLIENT FIFO test
also passed with an assertion on the frame-plus-fraction derived from the
replicated cycle (27 focused tests total). Changed Apple-only sources passed
syntax parsing on Windows; this is not Apple type-check/build or device proof.

Latest inspected Apple CI for preceding commit 7e5aaa4 (run 39011663881) built
and launched the host but failed package tests. Failures include unavailable
canonical Studio appearance/bodygroup resolvers, sky texture availability,
platform-dependent allocation estimates and exact float comparisons. The
Source-engine goal remains incomplete; passing focused animation tests does
not clear these failures or establish release readiness.

## Canonical appearance route fixture correction (unreleased)

The Apple appearance failures were reproduced in test configuration: injected
count/base-only layouts were still being used by stock SetupHands, whose current
route also invokes SetSkin and GetBodyGroups. Production repository resolution
already decodes appearance from the validated asset; the count-only attestation
intentionally cannot supply unknown names or skin families.

Route fixtures now supply explicit synthetic appearance metadata (clearly named
fixture groups/submodels). The stock prop fixture supplies its own appearance
resolver, and the repository-backed bridge fixture installs the actual repository
layout resolver rather than only its body-value mutation callback. No shipped
MDL metadata is guessed, and no runtime fallback or failure boundary is relaxed.

Validation: 13 focused Windows tests passed: stock SetupHands and replacement,
stock SpawnIcon/gm_spawn/replication/undo, original Sandbox PlayerSpawn, bridge
transactional rejection, repository-backed layout resolution, appearance FIFO
and resource selection. A new count-only-layout test explicitly rejects skin
mutation and body-group name queries while preserving the exact canonical
snapshot/revision and pending journal. This corrects fixture coverage, not a
claim that shipped assets or physical iPad behavior have been newly validated.

## Inline Studio RLE rotation channels (unreleased)

ANIMROT pointer tables now retain immutable RLE axis streams alongside ANIMPOS.
Rotation sampling uses authored RadianEuler bases and per-axis scales (not the
bind quaternion as an Euler substitute), omits the base for per-channel DELTA,
and applies Source's >0.001 paired-sample threshold. Subframes convert both
sampled angles to quaternions, align their signs, normalize their linear blend,
and honor BONE_FIXED_ALIGNMENT for non-delta channels. Raw rotations retain
their existing precedence. Malformed compressed streams fail through the same
typed animation error boundary rather than falling back to bind pose.

References: fixed Source SDK 2013 commit c8f4c6351162fbff83bfa5a428d45d1e6eed3824,
bone_setup.cpp CalcBoneQuaternion and mathlib_base.cpp AngleQuaternion,
QuaternionAlign, QuaternionBlend (independent implementation).
https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/public/bone_setup.cpp

This does not implement external animation blocks, sections, IK, global delta
animation blending, activities/events or live first-person Metal playback.

Validation: 31 Windows animation/renderable/cache tests passed. Added coverage
checks all RadianEuler axes, non-midpoint normalized blending (distinct from
Euler interpolation), shortest-arc crossing, fixed alignment, channel DELTA,
combined position/rotation pointer tables, hierarchy and weighted geometry.
The weighted rotation test also checks normal/tangent rotation, handedness and
unchanged indices/material ranges. Malformed rotation RLE remains a typed
failure. Apple/Oracle/physical iPad behavior is not established by these tests.

## First-person animated render worker connection (unreleased)

The App's normal viewmodel refresh now captures one immutable CLIENT first-person
frame through the dedicated session lane. It passes that frame and a session-local,
thread-safe Studio animation resolver to the existing detached render worker.
The worker resolves the replicated cycle's sequence/frame/fraction and submits
the animated resource to the existing Metal scene builder publication channel.
Lua/entity state is not read from the render worker, and CPU skinning/asset decode
does not run on the movement/GLua lane. Decoded preparation is reused; skinned
vertex frames are not accumulated in the cache.

Pending render work is coalesced, with only one detached job active. A completed
older cycle may publish while a newer cycle of the same weapon/model/sequence
waits, avoiding perpetual cancellation when rendering is slower than fixed ticks.
Changed full handles, resources, sequences, session generations and build epochs
reject stale results. Decode/animation errors remain diagnosed failures, not
silently successful bind-pose animations, and identical build errors are logged
once until their state changes. Disconnect releases the session-owned cache.

Separate bone-merged hands, activity-driven sequence selection, animations using
external blocks/sections and actual iPad animation output still require work.

Validation: eight Windows cache/render-input/sequence integration tests passed.
They resolve a validated synthetic MDL/VVD/VTX asset on a detached task using
the captured replicated cycle, preserve subframe identity, reject stale full
handles/missing repository/invalid sequence, and distinguish coalescible cycle
updates from target switches. The live session input matches the atomic CLIENT
weapon/animation observation. App source syntax parsing passed; Apple type-check,
Metal submission and physical output remain unverified for this connection.

## Activity-driven ViewModel selection (unreleased)

Decoded sequence descriptors now retain activity names and signed authored
weights. The metadata library supports weighted activity selection, preserves
the current matching negative-weight sequence, applies Source's zero-weight
tuple rule, and rejects weight overflow or invalid random tickets. Activity
names are used rather than assuming an MDL's compiled enum index matches GLua.

When an asset metadata resolver is installed, SERVER SendWeaponAnim maps the
currently exposed GLua ACT constant to its name, resolves an authored sequence,
resets the canonical cycle/start time and retains real timing/frame metadata.
Those values follow the existing CLIENT snapshot and render-worker connection.
Unavailable activities return false without mutating animation state. Existing
event-only behavior remains when no metadata resolver is installed; it is not
evidence of drawable animation. CLIENT prediction remains explicitly rejected.

Weighted draws use a reproducible session metadata-resolver stream, isolated
from per-pellet and Lua random state. The default seed is host policy; exact
Windows global RNG consumption, all/custom ACT registrations and prediction
shared-random parity are not asserted. Selection mechanics are grounded in
Valve Source SDK 2013 animation.cpp SelectWeightedSequence and studio.cpp's
activity-to-sequence tuple initialization (independent implementation).
https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/game/shared/animation.cpp

Validation: 36 focused Windows tests passed across sequence selection, RLE pose,
animated geometry/cache and original Base PrimaryAttack. Coverage includes exact
weight-ticket boundaries, negative current weights without RNG consumption,
zero/overflow weights, unavailable activities, repeatable bounded random draws,
SERVER SendWeaponAnim resetting real sequence timing and CLIENT FIFO cycle
observation. Original clip consumption, bullet trace/damage/event replication
also passed after the integer RNG addition; its existing float path is unchanged.
Apple, real-model activity playback and physical iPad results remain unverified.

## VGUI direct-child query index (unreleased)

GetChildren and ChildrenSize previously scanned the entire registry on every
query, and GetChildren also sorted every panel ID. A lazy parent-to-child-ID
index now amortizes that scan/sort across queries while the topology is stable.
Creation, destruction, SetParent and ParentToHUD invalidate it before callbacks
can observe changed membership. Child ID order, dynamic size reads, validity
checks and WorldPanel's HUD exclusion are preserved. Only integer IDs are
cached, not Lua values or userdata, so this adds no panel GC roots.

Internal work counters distinguish index rebuilds and direct-child candidates
visited, allowing bounded-work assertions independent of machine timing.
This optimizes repeated Derma layout/control queries; it does not assert that
all Q/C menu startup, layout or frame costs have been removed.

Validation: 63 Windows VGUI/notification tests passed, including stock controls,
layout, touch resizing, pointer capture, GC and notification expiry/isolation.
With 516 panels, 100 paired child-list/extent queries rebuilt the index once
and visited 400 direct-child candidates (plus the one index construction),
rather than repeatedly scanning every panel. Reparent callbacks observed the
new membership; HUD exclusion, deferred removal, recreation and live size
updates remained correct. No iPad response-time improvement is claimed without
physical measurement.

## Overlay capture and menu input propagation work reduction (unreleased)

Overlay descriptor collection previously built a live dictionary and a second
parent map for every registered WorldPanel before selecting notices. Each
overlay frame invokes this collection in multiple layout/Think/paint phases.
It now traverses the indexed OverlayPanel subtree directly, reading live
visibility, geometry and validity at each phase. Full foreground capture is
unchanged; topology mutations still invalidate the ID index immediately.

Recursive SetKeyboardInputEnabled also uses direct-child adjacency instead of
scanning every registered panel once per descendant. This reduces opening/
closing a large menu's input propagation from a repeated global scan to its
own subtree, without removing any native input-state update or Lua callback.

Validation: 63 Windows VGUI/notification tests passed. With 512 unrelated
WorldPanel panels, overlay-frame candidate visits stayed below 64; 100 further
visibility checks visited exactly 100 notice candidates with no index rebuild.
Moving a notice out of and back into OverlayPanel changed visibility correctly,
while full capture retained all WorldPanel layout/Think behavior. Keyboard
propagation over 512 descendants plus verification made 2,050 direct-child
candidate visits (including a separate two-child root), no index rebuild, and
left unrelated input state unchanged. These are bounded-work measurements,
not physical-iPad latency results.

## Incremental VGUI topology maintenance (unreleased)

After its initial lazy construction, the direct-child index now updates only
affected parent buckets on creation, SetParent, ParentToHUD and destruction.
New monotonic IDs append without retaining a second sibling-array reference;
reparented IDs are inserted in native ID order. Removed subtrees drop their
buckets together, with only edges from surviving parents individually removed.
Updates still occur before Lua callbacks observe the relationship. HUD/root
flag-only changes retain dynamic filtering without rebuilding the index.

This supersedes the earlier topology-invalidation policy: new notices no longer
force a rebuild of the unrelated spawn-menu hierarchy. Other deletion/layout
traversals are not claimed to be globally scan-free.

Validation: 64 Windows VGUI/notification tests passed. A warm index survived
64 notice create/reparent/reparent/remove cycles beside 512 unrelated panels
with zero global rebuilds and 384 edge updates. Native child order, reentrant
parent callback observations, live geometry, deferred deletion, recreation,
HUD filtering, GC, touch and notifications retained their tested behavior.
Physical iPad timings remain unmeasured.
# Options entry point follow-up

- Resource layout is now applied on initial layout and viewport changes, not every captured frame. This avoids resetting live touch-dragged/resized frames to authored positions and repeated Lua geometry calls. All coordinates are resolved before applying any live geometry. Regression drags a resource frame by 40px, verifies five idle layouts preserve it, then verifies a viewport change reapplies resource coordinates. Windows resource tests: 5 passed, 1 installed-resource test skipped. Physical-device behavior remains unverified.

- Native resource CheckButton now creates the stock DCheckBoxLabel, retaining its caption instead of only the bare DCheckBox. Authored `selected` accepts 0/1 and calls SetChecked; the host can read actual user changes through isChecked. Regression verifies caption rendering, selected=true, pointer toggle to false, and rejection of invalid selection. Windows resource suite: 4 passed, 1 installed-resource test skipped (asset not supplied). This does not supply missing Options resources or bind arbitrary cvars.

- Subtree deletion now snapshots parent edges once per traversal, preserving the previous dictionary sibling order for OnRemove while removing the per-descendant whole-registry scan. Traversal cost changes from O(panel count times subtree size) to O(panel count plus subtree size). A 128-level regression verifies exactly-once callbacks and survival of a reparented child. Focused registry/notification/MENU tests: 70 passed on Windows; no device latency claim.

- The HTML command parser accepted `gamemenucommand OpenOptionsDialog` but silently ignored the direct engine entry point `RunGameUICommand("OpenOptionsDialog")`. Route this entry point to the existing layered MENU utility; also route its disconnect/resume/problems/quit commands. Unknown commands now appear in the Playgrounds console instead of disappearing silently.
- Added parser regression assertions for direct Options, disconnect, unknown commands and quoted non-calls. Parser source type-checks on Windows. The standalone Swift interpreter could not execute the assertions because its JIT failed to resolve Foundation symbols; this is not a runtime test pass. Existing MENU settings/proble​​ms close/reopen tests: 5 passed.
- This addresses a missing entry point, not confirmed attribution of the physical-device failure. The current settings utility is still the limited host-backed Derma settings window, not complete original Source Options resource parity. Physical iPad opening remains unverified.
- Deferred VGUI deletions now use a minimum-ID worklist instead of scanning every panel on each idle frame. Registry/notification focused tests: 64 passed, including no idle removal-candidate visits after notice removal.

