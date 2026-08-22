# Source surface/material response attestation

`SurfaceMaterialResponseAttestation-v1.schema.json` and
`SourceOracleSurfaceMaterialAttestationCommon.ps1` define the versioned,
host-validated surface-response extension of the existing token-gated VPhysics
Windows Sandbox oracle. The authored-only test is:

```powershell
.\Tools\SourceOracle\Test-SourceOracleSurfaceMaterialAttestation.ps1
```

The fixed request is bound to AppID `4020`, branch `x86-64`, build
`24721267`, its fresh request ID, the exact `vphysics.dll`, all three surface
property inputs, and `gm_flatgrass.bsp` SHA-256 values. The host and guest each
cross-check those bindings against the manifest-verified, read-only input.
Immediately before `srcds` launch, the guest re-opens every file actually
copied from the bounded manifest with exclusive sharing, recomputes its
SHA-256, and compares it with the manifest declaration. The local
`vphysics.dll`, `gm_flatgrass.bsp`, and all three surface-property inputs are
also compared directly with the fixed provenance hashes.
Workshop, installed addons, user Lua, and networking remain disabled.

The probe records these independent routes without inferring missing values:

- each requested name through `util.GetSurfaceIndex`,
  `util.GetSurfacePropName`, and `util.GetSurfaceData`;
- the model's bone surface name, the bounded PHY `surfaceprop`, the original
  `PhysObj:GetMaterial`, and both `PhysicsCollide` surface indices;
- two fixed world-only traces, including `HitTexture`, `SurfaceProps`, reverse
  name, and the separately authenticated map hash;
- the bounded `PhysObj:GetFrictionSnapshot` entries for one controlled
  `plastic`-against-`rubber` contact;
- collision callback positions, normals, old/new linear velocities, old
  angular velocities, hit speed, scalar speed, and delta time. These remain raw
  evidence so restitution can be recomputed on the host rather than asserted by
  Lua.

All surface-response floating-point values are JSON strings emitted with
`string.format("%.9g", value)`. The host accepts only canonical finite Float32
`G9` text that round-trips bit-exactly. The schema exposes one
`friction_coefficient` from the original friction snapshot; it does not claim
separate static and dynamic coefficients.

`complete` requires every requested lookup, every model route, both fixed world
traces, a callback sample, at least one bounded controlled-pair friction
snapshot, no issues, and next-tick proof that both spawned entities were
removed. Unknown or missing surfaces, duplicate names/indices/records,
non-finite or non-round-tripping values, reverse-name mismatches, missing
observations, and unclean cleanup are accepted only as `partial`/`failure` and
can never validate as `complete`.

The JSON schema makes the complete-result cardinalities and fixed route/trace
identifiers independently rejectable: exactly two requested lookups, all five
model-route stages, both world-trace IDs, at least one controlled-pair
snapshot, and exactly one collision sample. The schema is a structural gate,
not the authority for exact fixed-value correlations. Exact input hashes,
request binding, index/name reversals, surface-to-route relationships, and
canonical Float32 text are normatively enforced by the host validator in
`SourceOracleSurfaceMaterialAttestationCommon.ps1`.

The static test does not launch Garry's Mod, Steam, Windows Sandbox, or any
other process, and it performs no installed-game or network access.
