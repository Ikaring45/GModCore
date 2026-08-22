# Standalone VPhysics partial attestation

`Results/vphysics-standalone-button06-build24721267-incomplete.json` is the
unchanged 1,828-byte output from one bounded standalone process. It did not
launch Garry's Mod, `srcds`, Steam, a gamemode, an addon, or Windows Sandbox.
The helper and loaded modules had no networking-library imports. The process
read only the exact 1,314,816-byte `vphysics.dll`, 2,540-byte MDL, and 880-byte
PHY inputs and could create only one result of at most 64 KiB. Its host timeout
was 15 seconds; the result reports 56 ms.

## Exact provenance

- Steam AppID 4020, `x86-64`, build `24721267`
- `vphysics.dll` SHA-256:
  `4ebd6149f885dfc518a44dd32dda64cbd6ebb3f938d43bdead70e80771b7e414`
- external helper source SHA-256:
  `1c51b892d06031bfa80600e7ab3fc0091b03afc182039e1192bed968ffd939f2`
- external helper executable SHA-256:
  `cc7a9c846383b916193bce189f5a5e2949c6829524a7d97df0a88aa45540407c`
- checked-in result SHA-256:
  `1c429a4a65063dc123509b6eaa435cd3fca16904445d958badbc3a6d50b12bcc`
- public ABI reference: Valve Source SDK 2013 commit
  `c8f4c6351162fbff83bfa5a428d45d1e6eed3824`, interfaces
  `VPhysicsCollision007` and `VPhysics031`

The helper source and binary remain in external scratch. No SDK header or
binary is copied into this repository.

## What the run established

`VCollideLoad`, `CollideGetAABB`, and `CollideGetMassCenter` completed against
the exact installed DLL and PHY. The checked-in result therefore records the
engine-produced collision AABB and center of mass. It also records the exact
raw PHY values `mass=3.000000`, `surfaceprop=plastic`, `damping=0.000000`,
`rotdamping=0.000000`, `inertia=1.000000`, and `volume=296.659119`.

The guarded process then raised Windows exception `0xC0000005` at stage 2,
when entering the public-SDK-layout query-model path. Per the one-run policy it
was not retried. Consequently the empty geometry, zero object mass/inertia,
false object flags, and material index `-1` are explicit unavailable sentinels,
not measured values.

This capture does **not** attest triangle geometry/material indices,
`IPhysicsObject` mass/principal inertia/flags, Garry's Mod
`util.IsValidProp`, entity OBB/collision bounds, or the GMod surface database
index. It must not construct `SourceAttestedPropPhysicsAsset`. The checked-in
schema intentionally accepts only this incomplete state, and the focused
validator asserts production eligibility remains false:

```powershell
.\Tools\SourceOracle\Test-SourceOracleVPhysicsStandaloneAttestation.ps1
```
