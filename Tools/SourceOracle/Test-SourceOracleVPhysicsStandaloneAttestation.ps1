[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$resultPath = Join-Path $toolRoot 'Results/vphysics-standalone-button06-build24721267-incomplete.json'
$schemaPath = Join-Path $toolRoot 'VPhysicsStandaloneAttestation-Incomplete.schema.json'

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Field
    )
    if ($Actual -ne $Expected) {
        throw "$Field mismatch: expected '$Expected', got '$Actual'"
    }
}

if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    throw "missing standalone VPhysics result: $resultPath"
}
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "missing standalone VPhysics schema: $schemaPath"
}

$resultBytes = [IO.File]::ReadAllBytes($resultPath)
Assert-Equal $resultBytes.Length 1828 'result byte count'
$resultHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resultPath).Hash.ToLowerInvariant()
Assert-Equal $resultHash '1c429a4a65063dc123509b6eaa435cd3fca16904445d958badbc3a6d50b12bcc' 'result SHA-256'

$result = [Text.Encoding]::UTF8.GetString($resultBytes) | ConvertFrom-Json -Depth 32
$schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $schemaPath | ConvertFrom-Json -Depth 32
Assert-Equal $schema.'$schema' 'https://json-schema.org/draft/2020-12/schema' 'schema dialect'
Assert-Equal $schema.title 'Bounded standalone VPhysics partial attestation' 'schema title'

Assert-Equal $result.schema 1 'schema'
Assert-Equal $result.kind 'standalone-vphysics-collision-attestation' 'kind'
Assert-Equal $result.status 'incomplete' 'status'
Assert-Equal $result.source_sdk_commit 'c8f4c6351162fbff83bfa5a428d45d1e6eed3824' 'Source SDK commit'
Assert-Equal $result.interfaces.collision 'VPhysicsCollision007' 'collision interface'
Assert-Equal $result.interfaces.physics 'VPhysics031' 'physics interface'

Assert-Equal $result.input.app_id 4020 'AppID'
Assert-Equal $result.input.branch 'x86-64' 'branch'
Assert-Equal $result.input.build_id '24721267' 'build ID'
Assert-Equal $result.input.dll_sha256 '4ebd6149f885dfc518a44dd32dda64cbd6ebb3f938d43bdead70e80771b7e414' 'vphysics.dll SHA-256'
Assert-Equal $result.input.dll_architecture 'x86_64' 'DLL architecture'
Assert-Equal $result.input.model_path 'models/maxofs2d/button_06.mdl' 'model path'
Assert-Equal $result.input.mdl_bytes 2540 'MDL byte count'
Assert-Equal $result.input.mdl_sha256 '85dca39870932c39dd1bcd51afbb0fc09aaf8d90fadfeb222e7b49cd784e0f07' 'MDL SHA-256'
Assert-Equal $result.input.phy_bytes 880 'PHY byte count'
Assert-Equal $result.input.phy_sha256 '8901ecd8be29b5a3e5b688843bdbea13f34c7b76c5a63cb435f9ef1174527ef3' 'PHY SHA-256'
Assert-Equal $result.input.studio_checksum -1817891700 'Studio checksum'
Assert-Equal $result.input.solid_index 0 'solid index'

Assert-Equal $result.phy_keyvalues.mass_raw '3.000000' 'raw mass'
Assert-Equal $result.phy_keyvalues.surfaceprop_raw 'plastic' 'raw surfaceprop'
Assert-Equal $result.phy_keyvalues.damping_raw '0.000000' 'raw damping'
Assert-Equal $result.phy_keyvalues.rotdamping_raw '0.000000' 'raw rotational damping'
Assert-Equal $result.phy_keyvalues.inertia_scale_raw '1.000000' 'raw inertia scale'
Assert-Equal $result.phy_keyvalues.volume_raw '296.659119' 'raw volume'

Assert-Equal $result.collision.complete $false 'collision completeness'
Assert-Equal $result.collision.solid_count 1 'loaded solid count'
Assert-Equal $result.collision.convex_count 0 'unavailable convex count'
Assert-Equal $result.collision.triangle_count 0 'unavailable triangle count'
Assert-Equal $result.collision.parts.Count 0 'unavailable geometry parts'
Assert-Equal ($result.collision.aabb_mins -join ',') '-8,-4.00000048,-2.51133247E-06' 'VPhysics AABB mins'
Assert-Equal ($result.collision.aabb_maxs -join ',') '8,4,2.54030132' 'VPhysics AABB maxs'
Assert-Equal ($result.collision.mass_center -join ',') '-2.58716373E-08,-5.88179432E-07,1.17415643' 'VPhysics mass center'

Assert-Equal $result.object.complete $false 'object completeness'
Assert-Equal $result.object.material_index_input -1 'unresolved material index sentinel'
Assert-Equal $result.object.mass_kg 0 'unavailable object mass sentinel'
Assert-Equal ($result.object.principal_inertia -join ',') '0,0,0' 'unavailable principal inertia sentinel'
Assert-Equal $result.guard.abi_call_returned $false 'ABI guard return'
Assert-Equal $result.guard.stage 2 'ABI guard stage'
Assert-Equal $result.guard.exception_code 3221225477 'ABI exception code'

Assert-Equal $result.scope.gmod_or_srcds_launched $false 'GMod/srcds launch scope'
Assert-Equal $result.scope.steam_launched $false 'Steam launch scope'
Assert-Equal $result.scope.network_used_by_probe $false 'network scope'
Assert-Equal $result.scope.util_is_valid_prop_attested $false 'util.IsValidProp scope'

$productionEligible = $result.collision.complete -and
    $result.collision.parts.Count -gt 0 -and
    $result.object.complete -and
    $result.object.material_index_input -ge 0
Assert-Equal $productionEligible $false 'production attested-asset eligibility'

Write-Host 'PASS: standalone VPhysics partial result is byte-pinned and remains production-ineligible'
