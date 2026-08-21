# Clean VPhysics sandbox workspace

This tool assembles and revalidates the bounded input used by the separately
reviewed AppID 4020 VPhysics Windows Sandbox single-run path. The workspace
generator itself does **not** download, launch, load a DLL, or change firewall
policy.

Run the synthetic/static test with:

```powershell
.\Tools\SourceOracle\Test-SourceOracleVPhysicsSandboxWorkspace.ps1
```

The generator is:

```powershell
.\Tools\SourceOracle\New-SourceOracleVPhysicsSandboxWorkspace.ps1 `
  -SourceRoot C:\explicit\fresh-app-4020-input `
  -InputSpecPath C:\explicit\app-4020-allowlist.json `
  -WorkspacePath C:\explicit\new-workspace
```

The exact non-launch x86-64 input selected for AppID 4020 build `24721267`
has a separate bounded staging command:

```powershell
.\Tools\SourceOracle\New-SourceOracleVPhysicsBuild24721267Stage.ps1 `
  -InstalledServerRoot H:\explicit\fresh-app-4020-x86-64 `
  -StagePath H:\explicit\new-empty-stage
```

Its checked-in spec selects `srcds_win64.exe`, the statically identified
64-bit bootstrap/interface/import closure, the exact Steam appmanifest, the
fixed `gm_flatgrass` map and GMod startup Lua, three surface-property files,
four controlled gamemode files, one probe, one guest bootstrap, and only four
`button_06` VPK entries. The staging code authenticates the bounded directory
VPK and target ranges, and does not rehash or copy the complete VPK chunk.

The input spec is schema 1 and has the exact object shape below. Every file is
copied through one retained, non-share-write handle only after its byte cap and
lowercase SHA-256 match. Paths are explicit; no glob or directory copy exists.

```json
{
  "schema": 1,
  "kind": "fresh-steamcmd-app-4020-x86-64-attestation-input",
  "steam": { "app_id": 4020, "branch": "x86-64", "build_id": "12345678" },
  "ownership_reference": "non-secret owned-install reference",
  "server": {
    "executable_input_path": "server/srcds.exe",
    "engine_input_path": "server/bin/win64/engine.dll",
    "game_server_input_path": "server/bin/win64/server.dll",
    "vphysics_input_path": "server/bin/win64/vphysics.dll",
    "tier0_input_path": "server/bin/win64/tier0.dll"
  },
  "model": {
    "model_path": "models/owned_fixture/attested_prop.mdl",
    "phy_path": "models/owned_fixture/attested_prop.phy"
  },
  "files": [
    {
      "role": "server_executable",
      "source_path": "srcds.exe",
      "input_path": "server/srcds.exe",
      "sha256": "64 lowercase hex characters",
      "maximum_bytes": 1048576
    }
  ]
}
```

Exactly one entry is required for each of `server_executable`,
`engine_module`, `game_server_module`, `vphysics_module`, `tier0_module`,
`model_mdl`, and `model_phy`. Extra explicitly hashed files may use
`server_runtime`, `shipped_content`, or `shipped_lua`. The two model entries
must be written to `oracle_game/<logical model path>`. Any path containing an
`addons` component is rejected.

The new workspace contains only:

- `input/`: copied allowlisted files, the normalized spec, an exact generated
  manifest, and explicitly empty `oracle_game/cfg/mount.cfg` and
  `mountdepots.txt`;
- `output/`: an empty directory;
- `SourceVPhysicsAttestation.wsb`: networking disabled, input mapped read-only,
  output mapped writable, and no logon command;
- `workspace.json`: `probe_enabled=false` plus the manifest digest and fixed
  isolation policy.

The single-run runner calls `Assert-SourceOracleVPhysicsSandboxWorkspace`
before it creates the read-only token/request mapping. The prerequisite WSB
remains nonlaunch; the separately generated launch WSB has exactly three
mappings, networking disabled, and one fixed guest bootstrap command.
