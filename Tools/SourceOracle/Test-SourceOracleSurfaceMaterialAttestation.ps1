$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'SourceOracleVPhysicsAttestationCommon.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsSandboxRun.ps1')

function Assert-SurfaceTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-SurfaceThrows([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-SurfaceTest $threw $Message
}

function Copy-SurfaceJSON([object]$Value) {
    return $Value | ConvertTo-Json -Depth 32 -Compress | ConvertFrom-Json
}

function New-SurfaceVector([string]$X, [string]$Y, [string]$Z) {
    return [pscustomobject][ordered]@{ x = $X; y = $Y; z = $Z }
}

$requestID = '0123456789abcdef0123456789abcdef'
$metadata = Read-SourceOracleVPhysicsBoundedJSON `
    -Path (Join-Path $toolRoot 'VPhysicsAttestation-Button06-AllowlistMetadata.json') `
    -MaximumBytes 65536 `
    -Field 'surface validator metadata'
$request = New-SourceOracleVPhysicsFixedRequest `
    -RequestID $requestID -Metadata $metadata

$plasticData = [pscustomobject][ordered]@{
    name = 'plastic'
    friction_coefficient = '0.800000012'
    elasticity = '0.25'
    density = '700'
    thickness = '0'
    dampening = '0'
    material = [int64]76
}
$rubberData = [pscustomobject][ordered]@{
    name = 'rubber'
    friction_coefficient = '0.899999976'
    elasticity = '0.800000012'
    density = '1522'
    thickness = '0'
    dampening = '0'
    material = [int64]76
}
$surfaceResult = [pscustomobject][ordered]@{
    schema = [int64]1
    kind = 'source-surface-material-response-attestation'
    status = 'complete'
    provenance = Copy-SurfaceJSON $request.surface_probe.provenance
    surface_lookups = @(
        [pscustomobject][ordered]@{
            requested_name = 'plastic'; surface_index = [int64]7
            reverse_name = 'plastic'; data = $plasticData
        },
        [pscustomobject][ordered]@{
            requested_name = 'rubber'; surface_index = [int64]11
            reverse_name = 'rubber'; data = $rubberData
        }
    )
    model_route = @(
        [pscustomobject][ordered]@{
            stage = 'mdl_bone'; surface_name = 'plastic'
            surface_index = [int64]7; reverse_name = 'plastic'
        },
        [pscustomobject][ordered]@{
            stage = 'phy_solid'; surface_name = 'plastic'
            surface_index = [int64]7; reverse_name = 'plastic'
        },
        [pscustomobject][ordered]@{
            stage = 'physobj'; surface_name = 'plastic'
            surface_index = [int64]7; reverse_name = 'plastic'
        },
        [pscustomobject][ordered]@{
            stage = 'callback_our'; surface_name = 'plastic'
            surface_index = [int64]7; reverse_name = 'plastic'
        },
        [pscustomobject][ordered]@{
            stage = 'callback_their'; surface_name = 'rubber'
            surface_index = [int64]11; reverse_name = 'rubber'
        }
    )
    world_traces = @(
        [pscustomobject][ordered]@{
            id = 'flatgrass-center'
            start = Copy-SurfaceJSON @($request.surface_probe.world_traces)[0].start
            end = Copy-SurfaceJSON @($request.surface_probe.world_traces)[0].end
            hit = $true; hit_world = $true
            hit_position = New-SurfaceVector '0' '0' '0'
            fraction = '0.5'; hit_texture = 'nature/blendgroundtograss001'
            surface_index = [int64]3; reverse_name = 'grass'
            surface_data_name = 'grass'
        },
        [pscustomobject][ordered]@{
            id = 'flatgrass-offset'
            start = Copy-SurfaceJSON @($request.surface_probe.world_traces)[1].start
            end = Copy-SurfaceJSON @($request.surface_probe.world_traces)[1].end
            hit = $true; hit_world = $true
            hit_position = New-SurfaceVector '1024' '1024' '0'
            fraction = '0.5'; hit_texture = 'nature/blendgroundtograss001'
            surface_index = [int64]3; reverse_name = 'grass'
            surface_data_name = 'grass'
        }
    )
    controlled_pairs = @(
        [pscustomobject][ordered]@{
            pair_id = 'plastic-against-rubber'; snapshot_ordinal = [int64]0
            material = [int64]7; material_other = [int64]11
            material_name = 'plastic'; material_other_name = 'rubber'
            friction_coefficient = '0.720000029'
            normal_force = '19.625'; energy_absorbed = '4.25'
            normal = New-SurfaceVector '0' '0' '1'
            contact_point = New-SurfaceVector '0' '0' '512'
        }
    )
    collision_samples = @(
        [pscustomobject][ordered]@{
            sample_id = 'controlled-pair-collision'
            pair_id = 'plastic-against-rubber'
            our_surface_index = [int64]7; their_surface_index = [int64]11
            our_surface_name = 'plastic'; their_surface_name = 'rubber'
            hit_position = New-SurfaceVector '0' '0' '514'
            hit_normal = New-SurfaceVector '0' '0' '1'
            hit_speed = New-SurfaceVector '0' '0' '-128'
            our_old_velocity = New-SurfaceVector '0' '0' '-128'
            their_old_velocity = New-SurfaceVector '0' '0' '0'
            our_new_velocity = New-SurfaceVector '0' '0' '32'
            their_new_velocity = New-SurfaceVector '0' '0' '0'
            our_old_angular_velocity = New-SurfaceVector '0' '0' '0'
            their_old_angular_velocity = New-SurfaceVector '0' '0' '0'
            speed = '128'; delta_time = '0.0151515156'
        }
    )
    cleanup = [pscustomobject][ordered]@{
        spawned_entity_count = [int64]2
        removed_entity_count = [int64]2
        clean = $true
    }
    issues = @()
}

$validated = Assert-SourceOracleSurfaceMaterialAttestation `
    -Result $surfaceResult `
    -SurfaceProbe $request.surface_probe `
    -RequestID $requestID
Assert-SurfaceTest ([string]$validated.status -ceq 'complete') `
    'Valid complete surface attestation was rejected'

$unknown = Copy-SurfaceJSON $surfaceResult
$unknown.surface_lookups[0].requested_name = 'unknown_surface'
$unknown.surface_lookups[0].reverse_name = 'unknown_surface'
$unknown.surface_lookups[0].data.name = 'unknown_surface'
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $unknown -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Complete result accepted an unknown surface instead of the requested surface'

$missing = Copy-SurfaceJSON $surfaceResult
$missing.surface_lookups = @($missing.surface_lookups[0])
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $missing -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Complete result accepted a missing requested surface'

$duplicate = Copy-SurfaceJSON $surfaceResult
$duplicate.surface_lookups[1].requested_name = 'plastic'
$duplicate.surface_lookups[1].reverse_name = 'plastic'
$duplicate.surface_lookups[1].data.name = 'plastic'
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $duplicate -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Complete result accepted a duplicate surface lookup'

$nonfinite = Copy-SurfaceJSON $surfaceResult
$nonfinite.surface_lookups[0].data.friction_coefficient = 'NaN'
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $nonfinite -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Surface validator accepted a nonfinite coefficient'

$notRoundTrip = Copy-SurfaceJSON $surfaceResult
$notRoundTrip.surface_lookups[0].data.friction_coefficient = '0.8'
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $notRoundTrip -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Surface validator accepted text that is not canonical Float32 %.9g round trip'

$reverseMismatch = Copy-SurfaceJSON $surfaceResult
$reverseMismatch.model_route[2].reverse_name = 'rubber'
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $reverseMismatch -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Surface validator accepted a reverse-name mismatch'

$uncleanComplete = Copy-SurfaceJSON $surfaceResult
$uncleanComplete.cleanup.removed_entity_count = [int64]1
$uncleanComplete.cleanup.clean = $false
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $uncleanComplete -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Unclean cleanup was accepted as complete'

$uncleanPartial = Copy-SurfaceJSON $uncleanComplete
$uncleanPartial.status = 'partial'
$uncleanPartial.issues = @('cleanup-incomplete')
$partial = Assert-SourceOracleSurfaceMaterialAttestation `
    -Result $uncleanPartial `
    -SurfaceProbe $request.surface_probe `
    -RequestID $requestID
Assert-SurfaceTest ([string]$partial.status -ceq 'partial') `
    'Explicit unclean partial result was not retained as partial'

$wrongRequestID = Copy-SurfaceJSON $surfaceResult
$wrongRequestID.provenance.request_id = 'ffffffffffffffffffffffffffffffff'
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $wrongRequestID -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Surface provenance was not bound to the request ID'

$wrongInputHash = Copy-SurfaceJSON $surfaceResult
$wrongInputHash.provenance.surface_inputs[0].sha256 =
    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceMaterialAttestation `
        -Result $wrongInputHash -SurfaceProbe $request.surface_probe -RequestID $requestID | Out-Null
} 'Surface provenance accepted a mismatched surface input hash'

$duplicateRequest = Copy-SurfaceJSON $request.surface_probe
$duplicateRequest.requested_surface_names[1] = 'plastic'
Assert-SurfaceThrows {
    Assert-SourceOracleSurfaceProbeRequest `
        -SurfaceProbe $duplicateRequest -RequestID $requestID | Out-Null
} 'Surface request accepted duplicate requested names'

$schemaPath = Join-Path $toolRoot 'SurfaceMaterialResponseAttestation-v1.schema.json'
$schema = Read-SourceOracleVPhysicsBoundedJSON `
    -Path $schemaPath -MaximumBytes 131072 -Field 'surface response JSON schema'
Assert-SurfaceTest ([string]$schema.properties.kind.const -ceq
    'source-surface-material-response-attestation') `
    'Surface response JSON schema kind changed'
Assert-SurfaceTest ($null -ne $schema.'$defs'.float32g9) `
    'Surface response JSON schema lost the Float32 %.9g definition'
$schemaText = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8
if ($null -ne (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
    $schemaValid = Test-Json `
        -Json ($surfaceResult | ConvertTo-Json -Depth 32 -Compress) `
        -SchemaFile $schemaPath `
        -ErrorAction Stop
    Assert-SurfaceTest $schemaValid `
        'Authored complete surface result failed the versioned JSON schema'

    function Assert-SurfaceSchemaRejects([object]$Value, [string]$Message) {
        $accepted = $false
        try {
            $accepted = Test-Json `
                -Json ($Value | ConvertTo-Json -Depth 32 -Compress) `
                -SchemaFile $schemaPath `
                -ErrorAction Stop 2>$null
        } catch {
            $accepted = $false
        }
        Assert-SurfaceTest (-not $accepted) $Message
    }

    $schemaMissingLookup = Copy-SurfaceJSON $surfaceResult
    $schemaMissingLookup.surface_lookups = @($schemaMissingLookup.surface_lookups[0])
    Assert-SurfaceSchemaRejects $schemaMissingLookup `
        'Schema accepted complete with fewer than two surface lookups'

    $schemaDuplicateLookup = Copy-SurfaceJSON $surfaceResult
    $schemaDuplicateLookup.surface_lookups[1].requested_name = 'plastic'
    Assert-SurfaceSchemaRejects $schemaDuplicateLookup `
        'Schema accepted complete without exactly one plastic and one rubber lookup'

    $schemaMissingRoute = Copy-SurfaceJSON $surfaceResult
    $schemaMissingRoute.model_route = @($schemaMissingRoute.model_route)[0..3]
    Assert-SurfaceSchemaRejects $schemaMissingRoute `
        'Schema accepted complete with fewer than five model-route records'

    $schemaDuplicateRoute = Copy-SurfaceJSON $surfaceResult
    $schemaDuplicateRoute.model_route[4].stage = 'callback_our'
    Assert-SurfaceSchemaRejects $schemaDuplicateRoute `
        'Schema accepted complete without all five fixed model-route stages'

    $schemaMissingTrace = Copy-SurfaceJSON $surfaceResult
    $schemaMissingTrace.world_traces = @($schemaMissingTrace.world_traces[0])
    Assert-SurfaceSchemaRejects $schemaMissingTrace `
        'Schema accepted complete with fewer than two world traces'

    $schemaDuplicateTrace = Copy-SurfaceJSON $surfaceResult
    $schemaDuplicateTrace.world_traces[1].id = 'flatgrass-center'
    Assert-SurfaceSchemaRejects $schemaDuplicateTrace `
        'Schema accepted complete without both fixed world-trace IDs'

    $schemaMissingPair = Copy-SurfaceJSON $surfaceResult
    $schemaMissingPair.controlled_pairs = @()
    Assert-SurfaceSchemaRejects $schemaMissingPair `
        'Schema accepted complete without a controlled-pair friction snapshot'

    $schemaWrongPair = Copy-SurfaceJSON $surfaceResult
    $schemaWrongPair.controlled_pairs[0].pair_id = 'unrequested-pair'
    Assert-SurfaceSchemaRejects $schemaWrongPair `
        'Schema accepted complete without the fixed controlled-pair ID'

    $schemaMissingCollision = Copy-SurfaceJSON $surfaceResult
    $schemaMissingCollision.collision_samples = @()
    Assert-SurfaceSchemaRejects $schemaMissingCollision `
        'Schema accepted complete without exactly one collision sample'

    $schemaWrongCollision = Copy-SurfaceJSON $surfaceResult
    $schemaWrongCollision.collision_samples[0].sample_id = 'unexpected-sample'
    Assert-SurfaceSchemaRejects $schemaWrongCollision `
        'Schema accepted complete without the fixed collision sample ID'
}
Assert-SurfaceTest ($schemaText -notmatch '(?i)static[_ -]?friction|dynamic[_ -]?friction') `
    'Schema incorrectly claims separate static/dynamic friction coefficients'
Assert-SurfaceTest ($schemaText -match 'friction_coefficient') `
    'Schema does not expose the single combined friction coefficient'

$probeText = Get-Content -LiteralPath (Join-Path $toolRoot `
    'VPhysicsAttestationAddon\lua\autorun\server\garryspad_source_vphysics_attestation.lua'
) -Raw -Encoding UTF8
foreach ($required in @(
    'util.GetSurfaceIndex(',
    'util.GetSurfacePropName(',
    'util.GetSurfaceData(',
    'entity:GetBoneSurfaceProp(0)',
    'physics:GetMaterial()',
    'physics:GetFrictionSnapshot()',
    'data.OurSurfaceProps',
    'data.TheirSurfaceProps',
    'data.OurOldVelocity',
    'data.TheirOldVelocity',
    'data.OurNewVelocity',
    'data.TheirNewVelocity',
    'trace.HitTexture',
    'trace.SurfaceProps',
    'MASK_SOLID_BRUSHONLY',
    'string.format("%.9g", value)',
    'cleanup-incomplete'
)) {
    Assert-SurfaceTest ($probeText.Contains($required)) `
        "Surface probe is missing fixed observation token $required"
}
foreach ($forbidden in @(
    '\bnet\.', '\bhttp\.', '\bHTTP\s*\(', '\bsteamworks\.',
    '\bRunString\b', '\bCompileString\b', '\brequire\s*\('
)) {
    Assert-SurfaceTest ($probeText -notmatch $forbidden) `
        "Surface probe contains forbidden behavior $forbidden"
}

$guestText = Get-Content -LiteralPath (Join-Path $toolRoot `
    'Run-SourceOracleVPhysicsSandboxGuest.ps1'
) -Raw -Encoding UTF8
foreach ($required in @(
    "`$fixedVPhysicsSHA",
    "`$fixedSurfaceInputs",
    "'sourceengine/scripts/surfaceproperties_manifest.txt'",
    "'sourceengine/scripts/surfaceproperties.txt'",
    "'sourceengine/scripts/surfaceproperties_hl2.txt'",
    "'oracle_game/maps/gm_flatgrass.bsp'",
    'function Get-GuestCopiedFileSHA256',
    '[Security.Cryptography.SHA256]::Create()',
    '$sha.ComputeHash($stream)',
    '[IO.FileShare]::None',
    '$copiedManifestFiles',
    '$actualLocalHashes',
    'Copied local input SHA-256 differs from manifest',
    'Copied local input SHA-256 differs from fixed surface provenance'
)) {
    Assert-SurfaceTest ($guestText.Contains($required)) `
        "Guest runner is missing surface provenance binding $required"
}
$copyIndex = $guestText.IndexOf(
    '[IO.File]::Copy($source, $destination, $false)',
    [StringComparison]::Ordinal
)
$rehashIndex = $guestText.IndexOf(
    '$actualLocalHashes = @{}',
    [StringComparison]::Ordinal
)
$launchIndex = $guestText.IndexOf(
    '$processResult = [SourceOracleGuestProcessRunner]::Run(',
    [StringComparison]::Ordinal
)
Assert-SurfaceTest (
    $copyIndex -ge 0 -and $rehashIndex -gt $copyIndex -and
    $launchIndex -gt $rehashIndex
) 'Guest local-file rehash is not ordered after copy and immediately before launch'

$parserErrors = [Collections.Generic.List[object]]::new()
foreach ($scriptName in @(
    'SourceOracleSurfaceMaterialAttestationCommon.ps1',
    'Test-SourceOracleSurfaceMaterialAttestation.ps1',
    'Run-SourceOracleVPhysicsSandboxGuest.ps1'
)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $toolRoot $scriptName), [ref]$tokens, [ref]$errors
    )
    foreach ($error in $errors) { $parserErrors.Add($error) }
}
Assert-SurfaceTest ($parserErrors.Count -eq 0) `
    "Surface attestation scripts contain $($parserErrors.Count) parser error(s)"

Write-Output (
    'Source surface/material response validator tests passed ' +
    '(authored JSON only; no GMod, process, installed input, addon scan, or network action)'
)
