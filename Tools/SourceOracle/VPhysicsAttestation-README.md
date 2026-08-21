# Owned-model VPhysics attestation (not launch-enabled)

This directory now contains a bounded request/result contract and a dormant,
token-gated server probe for one explicit model path. Nothing here is connected
to either real-GMod runner. The non-launch test is:

```powershell
.\Tools\SourceOracle\Test-SourceOracleVPhysicsAttestation.ps1
```

The request is accepted only when it exactly matches the sole entry in a
separate owned-model allowlist: canonical lowercase GAME `.mdl` and derived
`.phy` paths, both SHA-256 values, and an ownership reference. No production
allowlist is checked in because no owned MDL/PHY pair has yet been selected.
Synthetic test values are not a model recommendation or an attestation.

The fixed request policy denies Workshop, installed addons, user Lua, and
network use. It also carries hard upper bounds for MDL/PHY bytes, PHY solids,
convexes, triangle-list vertices, result JSON bytes, and elapsed seconds. The
probe opens only the two allowlisted paths through `GAME`, validates their
hashes and the public MDL/PHY headers, checks `util.IsValidModel` and
`util.IsValidProp`, and then records physics object 0 through
`GetMeshConvexes`, `GetAABB`, `GetMassCenter`, `GetInertia`, `GetMass`, and
`GetMaterial`. Convex positions remain grouped and ordered; each three entries
are one triangle. No model, PHY, material, or other game asset bytes are
written to the result.

## Launch blockers

A real run remains prohibited until all of these are independently reviewed
and implemented:

1. The owner supplies exactly one authorized installed model path plus exact
   MDL/PHY SHA-256 values and a non-secret ownership reference.
2. A dedicated runner enforces the request contract before mounting or
   launching and authenticates the bounded result while its retained Job still
   has an active member.
3. That runner proves other installed addons and user Lua cannot execute. The
   existing `-noworkshop` runners do not establish this.
4. Network denial is enforced outside Lua and verified for the owned Job. The
   probe merely avoids network APIs; that is not an OS network sandbox.
5. The runner preserves the existing suspended-process Job, per-install mutex,
   handle-verified mount, default-deny launch switch, and fail-closed cleanup
   contracts. The dormant probe must not be added to an existing broad oracle
   as an incidental extra case.

Until those blockers are closed, do not add `-AllowRealGModLaunch`, do not
record output under `Results`, and do not promote synthetic data or the
structurally decoded Swift VPhysics snapshot to a `util.IsValidProp` golden.
