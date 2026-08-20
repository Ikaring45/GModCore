# Garry's PAD Source oracle

## Safety status

Real GMod execution is paused pending independent review of the hardened
runner. Both launch scripts fail closed unless the caller explicitly supplies
`-AllowRealGModLaunch`. Do not supply that switch merely to test the scripts;
run the GMod-free safety suite instead (the Job test uses only harmless
PowerShell parent/child fixtures):

```powershell
.\Tools\SourceOracle\Test-SourceOracleRunnerSafety.ps1
.\Tools\SourceOracle\Test-SourceOracleOwnedProcessJob.ps1
.\Tools\SourceOracle\Test-SourceOracleOwnedMount.ps1
```

The runner copies a fresh 32-hex launch token into only its marker-verified
temporary addon and passes that token to a probe-specific `+concommand` after
the map command. Loading the addon alone does not run the probe: the same
process must receive the exact command token. Result JSON is accepted only when
integer `schema == 1`, JSON booleans `enabled == true` and
`command_line_enabled == true`, exact `run_id`, exact `command_line_run_id`,
exact realm, the realm's successful `finish_reason`, and no `probe_error` all
match this invocation. A fresh timestamp alone is not sufficient. The result
is considered only while the retained Job Object still reports an active
member.

The launch boundary does not terminate by PID. `gmod.exe` is created suspended,
assigned to a private non-breakaway Windows Job Object configured with
`KILL_ON_JOB_CLOSE`, and resumed only after assignment succeeds. The runner
holds the Job and root-process handles for the full invocation; every normal or
failure cleanup uses those handles. There is no CIM, process-name, launch-time,
or PID-reuse cleanup fallback. Before mounting, the runner takes a per-install
mutex and fails closed if any `gmod.exe` already exists. It never stops that
process. If a broker creates an out-of-Job GMod, the postflight detects it,
does not stop it, and preserves the mount for manual audit.

Each run receives an atomically created random mount name. The mount helper
rejects reparse points, holds its target directory without delete sharing,
records the volume serial and 128-bit file IDs for every owned entry, and
manifests the generated run-token file. Cleanup first verifies the exact
run-ID/token marker and complete manifest, then marks those same retained file
and directory handles for deletion. Rename/swap, unknown entries, marker
changes, reparse points, or identity mismatches cause fail-closed preservation;
no recursive path-based deletion is attempted.

This harness records behavior from a legally installed Windows Garry's Mod.
It is a differential oracle, not a source of game assets. The generated JSON
contains only API results, numbers, strings, and callback ordering produced by
the original engine.

`Run-SourceOracle.ps1` handle-copies the dedicated addon into its owned mount,
launches a hidden windowed single-player session on `gm_flatgrass`, waits for
an authenticated JSON result, stops only its Job, and then deletes only its
handle-verified manifest. The workspace copy is not a normal installed addon.
The harness does not copy or redistribute GMod/HL2 files.

After independent safety review, a deliberate real run would require:

```powershell
.\Tools\SourceOracle\Run-SourceOracle.ps1 -AllowRealGModLaunch
.\Tools\SourceOracle\Run-SourceClientOracle.ps1 -AllowRealGModLaunch
```

The result is copied to `Tools/SourceOracle/Results/<run-id>.json`. Keep raw
oracle output separate from Swift expected values: a changed Windows build can
then be measured rather than silently changing the compatibility contract.

Current probes cover:

- engine build/branch and the fixed tick interval;
- addon-visible Tick, Think, and scripted-Entity Think ordering;
- canonical NULL/world Entity behavior and immediate EntIndex reuse;
- line and hull traces against an engine-linked `SOLID_BBOX`, including
  `StartSolid`, `AllSolid`, `FractionLeftSolid`, normals, and hit Entity;
- case-insensitive GAME/LUA reads and `file.Find` ordering;
- material handle identity and reported shader/dimensions for a stock debug
  material.

The second command runs the paired client oracle. It records prediction/move
hook ordering and CUserCmd fields, primitive and compound net-codec round
trips, and VGUI immediate/deferred layout plus text sizing. Movement outcomes,
VPhysics and animation still require additional controlled probes and must not
be inferred from these corpora.
