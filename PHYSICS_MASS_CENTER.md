# Authored rigid-body mass centers

## Contract and evidence

[Valve's published IPhysicsObject interface](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/public/vphysics_interface.h#L679)
separates the local mass center from the position matrix and defines offset
impulse calculations about the center of mass. The
[Facepunch GetMassCenter contract](https://wiki.facepunch.com/gmod/PhysObj:GetMassCenter)
returns a local vector. Valve's
[debug overlay](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/game/server/baseentity.cpp#L925)
also transforms that local center to world space separately from the object
origin. These public contracts do not expose the private VPhysics solver.

`SourcePhysicsMassProperties.massCenterLocal` now carries this authored Source
coordinate explicitly. Its principal inertia is about this center, in the
body-local principal axes already required by this backend. The existing Swift
initializer without a center retains the former zero-center body contract;
it does not calculate or authenticate a center for arbitrary model geometry.

## Connected behavior

- Dynamic and kinematic linear velocity advances the world mass center.
  Rotation updates the model origin so the same center is retained. Geometry,
  `GetPos`, and local/world conversions still use the authored model origin.
- Offset impulses and contact effective mass use the lever arm from the world
  mass center. `GetVelocityAtPoint` and `CalculateVelocityOffset` use that same
  center, and `GetMassCenter` returns the authoritative local value.
- Fixed-joint angular correction keeps each body's mass center stationary
  before its existing inverse-mass-weighted position correction. Its rigid
  velocity relationship uses the separation between mass centers.
- Static-world translational CCD sweeps the mass-center path, with geometry
  bounds relative to that center, then restores the authored model origin.
- The physgun derives both center and orientation targets from the local grab
  point. Its speed limits, ordinary gravity, FIFO, hooks, and full EHANDLE
  lifetime checks are retained.
- `SetMass` preserves the local center. Both the coordinator and replay reject
  a backend that silently changes it during a mass-only mutation.

Non-finite local centers or overflowing world centers are rejected. No center
is inferred from a bounding box, a visual mesh, or unattested raw IVP metadata.

## Data formats

New independent attestation manifests use `schemaVersion: 2`. Each asset must
include its authenticated `massCenterLocal` alongside the existing exact-byte
identity, Source axis convention, shape, mass, and inertia. For example, the
following is only a field illustration, not a usable attestation:

```json
"massCenterLocal": { "x": 2, "y": -3, "z": 1 }
```

Version 1 remains readable under its original origin-equals-center contract.
An omitted or explicitly zero center preserves that behavior; a nonzero center
under v1 is rejected instead of ignored. Version 2 requires the field, and
unknown versions are rejected. Exact MDL/PHY digest and independent provenance
checks are unchanged. The content pack still cannot self-attest.

Physics replay now uses version 12, storing the center in both creation and
snapshot mass properties. Earlier replay versions are rejected rather than
read with the wrong byte layout. Re-record them with the corrected backend;
do not relabel old bytes as v12.

## Remaining physical work and validation boundary

This is an extension of the existing deterministic backend, not a connection
to Valve's binary or a claim of complete VPhysics parity. The length-constraint
solver remains its existing translation-only approximation. Full asymmetric
torque-free dynamics, rotational/body-body CCD, contact manifolds, native
shadow-controller matching, and device acceptance remain open.

The new tests exercise analytical center-preserving rotation, rotated offset
impulses, equivalent solids with different model origins, SAT and static CCD,
fixed-joint total-center preservation, mass-change/replay round trips, format
migration, failure rollback, Lua reads, and the real session's physgun path.
Their synthetic independent attestations do not approve arbitrary owned props.
Apple build/Simulator checks and actual iPad spawn/fall/hold/drop behavior are
separate from Windows numerical tests.

## Windows validation, 2026-10-20

Swift 6.4.1, x86_64 Windows:

```sh
swift test --jobs 2 --filter 'Physics|Physgun|Thruster|GModStockPropVerticalIntegrationTests|GModAttestedPropRuntimeBridgeIntegrationTests'
```

58 XCTest tests and 97 Swift Testing tests passed, with zero failures or skips.
This includes the negative backend-center-change check, rollback and v1/v2
manifest compatibility, nonzero-center real-session physgun manipulation, and
equivalent-frame initial-contact/static-CCD checks. The previous Apple CI
success at `e46b56c` predates these physics changes and does not validate them.
