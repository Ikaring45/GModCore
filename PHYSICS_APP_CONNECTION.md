# App physics connection

The existing independent deterministic rigid-body backend is connected to the
SERVER fixed tick, canonical Entity/PhysObj state and FIFO replication. It is
not Valve's VPhysics binary, Jolt, or proof of complete Source physics parity.

The public Swift Playgrounds entry point now forwards an explicitly supplied
independently attested physics manifest to every map start:

```swift
GModMainView(attestedPropPhysicsManifestURL: manifestURL)
```

`manifestURL` must point to an app-readable file (copy an imported document into
app storage first). Mount the matching owned content ZIP before starting a map.
The existing loader checks the exact MDL/PHY digests, selected solid, geometry,
mass, inertia, axis convention and material data. A missing or invalid record
does not authorize guessed shapes or a dummy PhysObj. No manifest is bundled
or automatically trusted by this change.

No-argument `GModMainView()` remains supported. Without matching attested prop
data, arbitrary prop bodies remain unavailable; this API is not an assertion
that every Sandbox model now spawns physically. A built-in import UI and actual
iPad spawn/fall/settle/remove acceptance are still outstanding.

Validation: existing manifest/coordinator Windows suites, 13 tests passed.
Changed Apple app sources passed syntax parsing only; Apple typecheck/CI and
physical iPad integration remain unverified.

## Owned content diagnostic

The optional `GMOD_CONTENT_PACK_DIAGNOSTIC_PATH` integration test reads the
user-owned STORED ZIP without extraction. For `wood_crate001a`, archive inventory
found a single MDL in `sourceengine/hl2_misc_dir.vpk`: version 44, 1,604 bytes,
checksum -1388713967. This is not a newer model hidden by VPK mount precedence.
The matching 1,208-byte PHY passes checksum matching and decodes one collision
ledge, still explicitly unattested. The prefix identity reader accepts v44;
the Studio core now reads v44 bones, hitboxes and sequence metadata as well.
The v44 sequence tail is reserved, not an activity-modifier table. Record
The HL2 v44 hitbox-name address is absolute, unlike v48's record-relative
address. Game-specific v44 forks are not claimed supported. Record
layout evidence: Crowbar's original v44 reader at fixed commit
`0d46f3b6a694b74453db407c72c12a9685d8eb1d`,
[`ReadBones` and `ReadSequenceDescs`](https://github.com/ZeqMacaw/Crowbar/blob/0d46f3b6a694b74453db407c72c12a9685d8eb1d/Crowbar/Core/GameModel/SourceModel44/SourceMdlFile44.vb).
The owned MDL/VVD/DX90-VTX bundle now passes checksum/budget validation and
root-LOD mesh decoding (400 expanded vertices, 600 indices). Windows Studio
regressions pass. The renderer-neutral compiler also produces draw ranges, and
their authored VMT resolves `woodcrates01a` to a real 512-by-512 RGBA texture.
No fallback texture or guessed material is accepted by this integration test.
This is CPU decoding evidence, not a GPU screenshot or iPad
acceptance. Animation integration and rendering still require separate validation.
Neither structural collision decoding nor metadata parsing establishes drawable
or physically spawnable props.

Nested VPK reads now preserve backing-store errors (including unsupported ZIP
compression) instead of relabeling every failure as truncated VPK data. A
short successful read still correctly reports truncation.
