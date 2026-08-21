# Owned-model VPhysics attestation

This directory contains a bounded request/result contract, a token-gated server
probe for one explicit model path, and a separately isolated Windows Sandbox
single-run path. The static test is:

```powershell
.\Tools\SourceOracle\Test-SourceOracleVPhysicsAttestation.ps1
```

The request is accepted only when it exactly matches the sole checked-in owned
`button_06` allowlist entry: canonical lowercase GAME `.mdl` and derived `.phy`
paths, both SHA-256 values, and the owned-content manifest reference. It is also
the exact default Q-menu SpawnIcon entry pinned in the metadata.

The fixed request policy denies Workshop, installed addons, user Lua, and
network use. It also carries hard upper bounds for MDL/PHY bytes, PHY solids,
convexes, triangle-list vertices, result JSON bytes, and elapsed seconds. The
probe opens only the two allowlisted paths through `GAME`, validates their
hashes and the public MDL/PHY headers, checks `util.IsValidModel` and
`util.IsValidProp`, and then records physics object 0 through
`GetMeshConvexes`, `GetAABB`, `GetMassCenter`, `GetInertia`, `GetMass`, and
`GetMaterial`. At the fixed zero origin/angle it also records the spawned
entity's engine-owned `OBBMins`, `OBBMaxs`, and exact `GetCollisionBounds`
values. Convex positions remain grouped and ordered; each three entries are
one triangle. The entity is removed before the result is handed off. No model,
PHY, material, or other game asset bytes are written to the result.

## Single-run isolation

A real run uses `Invoke-SourceOracleVPhysicsSandboxRun.ps1` and remains
default-deny without `-AllowSingleSandboxLaunch`. Before Windows Sandbox starts,
the runner requires all of the following:

1. AppID 4020 x86-64 build `24721267` and the exact manifest-verified clean
   game root;
2. no inherited addons or user Lua, plus empty mount and depot configuration;
3. read-only input and request mappings, one initially empty writable result
   mapping, and Windows Sandbox networking disabled;
4. fixed `gm_flatgrass`, `garryspad_attestation`, 20-second probe timeout,
   60-second guest timeout, and 90-second host timeout;
5. a fresh 32-hex token and request ID, bounded result size, and full host-side
   result validation before the retained owned Windows Sandbox Job is released.

The guest copies individual manifest entries only; it does not copy a broad
installed tree. It exports only `result.json` or one bounded authenticated
`failure.json`, removes the spawned entity, and shuts down the disposable VM.
Do not promote synthetic data or a structurally decoded Swift snapshot to a
`util.IsValidProp` golden; only the validated real result can close that gate.
