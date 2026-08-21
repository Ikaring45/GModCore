$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$common = Join-Path $toolRoot 'SourceOracleVPhysicsAttestationCommon.ps1'
. $common

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

function Copy-JSONValue([object]$Value) {
    return $Value | ConvertTo-Json -Depth 32 -Compress | ConvertFrom-Json
}

$runID = '0123456789abcdef0123456789abcdef'
$requestID = 'fedcba9876543210fedcba9876543210'
$mdlSHA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$phySHA = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$ownership = 'synthetic-non-launch-fixture'
$modelPath = 'models/owned_fixture/attested_prop.mdl'
$phyPath = 'models/owned_fixture/attested_prop.phy'

$policy = [pscustomobject]@{
    search_path = 'GAME'
    allow_workshop = $false
    allow_installed_addons = $false
    allow_user_lua = $false
    allow_network = $false
}
$limits = [pscustomobject]@{
    maximum_mdl_bytes = [int64]1048576
    maximum_phy_bytes = [int64]1048576
    maximum_solids = [int64]8
    maximum_convexes = [int64]32
    maximum_vertices_per_convex = [int64]1024
    maximum_total_vertices = [int64]4096
    maximum_result_bytes = [int64]65536
    timeout_seconds = [int64]20
}
$request = [pscustomobject]@{
    schema = [int64]1
    request_id = $requestID
    model_path = $modelPath
    phy_path = $phyPath
    expected_mdl_sha256 = $mdlSHA
    expected_phy_sha256 = $phySHA
    ownership_reference = $ownership
    policy = $policy
    limits = $limits
}
$allowlist = [pscustomobject]@{
    schema = [int64]1
    models = @([pscustomobject]@{
        model_path = $modelPath
        phy_path = $phyPath
        mdl_sha256 = $mdlSHA
        phy_sha256 = $phySHA
        ownership_reference = $ownership
    })
}

$validatedRequest = Assert-SourceOracleVPhysicsRequestObject `
    -Request $request -Allowlist $allowlist
Assert-True ($validatedRequest.request_id -ceq $requestID) 'Valid request was rejected'

$invalidPath = Copy-JSONValue $request
$invalidPath.model_path = 'models/../outside.mdl'
Assert-Throws {
    Assert-SourceOracleVPhysicsRequestObject `
        -Request $invalidPath -Allowlist $allowlist | Out-Null
} 'Traversal model path was accepted'

$permissive = Copy-JSONValue $request
$permissive.policy.allow_network = $true
Assert-Throws {
    Assert-SourceOracleVPhysicsRequestObject `
        -Request $permissive -Allowlist $allowlist | Out-Null
} 'Network-permissive request was accepted'

$oversizedLimits = Copy-JSONValue $request
$oversizedLimits.limits.maximum_total_vertices = [int64]65537
Assert-Throws {
    Assert-SourceOracleVPhysicsRequestObject `
        -Request $oversizedLimits -Allowlist $allowlist | Out-Null
} 'Request exceeded the hard vertex cap'

$broadAllowlist = Copy-JSONValue $allowlist
$broadAllowlist.models = @($broadAllowlist.models, $broadAllowlist.models)
Assert-Throws {
    Assert-SourceOracleVPhysicsRequestObject `
        -Request $request -Allowlist $broadAllowlist | Out-Null
} 'More than one owned model was accepted'

$v1 = [pscustomobject]@{ x = [double]-1; y = [double]-2; z = [double]0 }
$v2 = [pscustomobject]@{ x = [double]1; y = [double]-2; z = [double]0 }
$v3 = [pscustomobject]@{ x = [double]0; y = [double]2; z = [double]3 }
$result = [pscustomobject]@{
    schema = [int64]1
    kind = 'owned-model-vphysics-attestation'
    enabled = $true
    command_line_enabled = $true
    run_id = $runID
    command_line_run_id = $runID
    request_id = $requestID
    realm = 'SERVER'
    finish_reason = 'vphysics-attestation-complete'
    model_path = $modelPath
    phy_path = $phyPath
    policy = Copy-JSONValue $policy
    runtime = [pscustomobject]@{
        version = [int64]260813
        version_string = '2026.08.13'
        branch = 'x86-64'
        is_windows = $true
        jit_arch = 'x64'
        map = 'gm_flatgrass'
    }
    files = [pscustomobject]@{
        mdl = [pscustomobject]@{
            byte_count = [int64]512
            sha256 = $mdlSHA
            magic = 'IDST'
            version = [int64]48
            checksum = [int64]270544960
        }
        phy = [pscustomobject]@{
            byte_count = [int64]256
            sha256 = $phySHA
            header_byte_count = [int64]16
            identifier = [int64]0
            solid_count = [int64]1
            checksum = [int64]270544960
        }
    }
    validity = [pscustomobject]@{
        util_is_valid_model = $true
        util_is_valid_prop = $true
    }
    entity_collision = [pscustomobject]@{
        origin = [pscustomobject]@{ x = [double]0; y = [double]0; z = [double]0 }
        angles = [pscustomobject]@{
            pitch = [double]0; yaw = [double]0; roll = [double]0
        }
        obb = [pscustomobject]@{
            minimum = [pscustomobject]@{ x = [double]-1; y = [double]-2; z = [double]0 }
            maximum = [pscustomobject]@{ x = [double]1; y = [double]2; z = [double]3 }
        }
        collision_bounds = [pscustomobject]@{
            minimum = [pscustomobject]@{ x = [double]-1; y = [double]-2; z = [double]0 }
            maximum = [pscustomobject]@{ x = [double]1; y = [double]2; z = [double]3 }
        }
    }
    physics = [pscustomobject]@{
        object_index = [int64]0
        convex_count = [int64]1
        total_vertex_count = [int64]3
        vertices_per_convex = @([int64]3)
        topology_sha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        aabb = [pscustomobject]@{
            minimum = [pscustomobject]@{ x = [double]-1; y = [double]-2; z = [double]0 }
            maximum = [pscustomobject]@{ x = [double]1; y = [double]2; z = [double]3 }
        }
        center_of_mass = [pscustomobject]@{ x = [double]0; y = [double]0; z = [double]1 }
        inertia = [pscustomobject]@{ x = [double]1; y = [double]2; z = [double]3 }
        mass = [double]10
        material = 'metal'
        convexes = ,@($v1, $v2, $v3)
    }
}

$validatedResult = Assert-SourceOracleVPhysicsResultObject `
    -Result $result -RunID $runID -Request $request
Assert-True ($validatedResult.physics.total_vertex_count -eq 3) 'Valid fingerprint was rejected'

$wrongHash = Copy-JSONValue $result
$wrongHash.files.phy.sha256 = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
Assert-Throws {
    Assert-SourceOracleVPhysicsResultObject `
        -Result $wrongHash -RunID $runID -Request $request | Out-Null
} 'Result not bound to the owned PHY hash was accepted'

$reversedAABB = Copy-JSONValue $result
$reversedAABB.physics.aabb.minimum.x = [double]2
Assert-Throws {
    Assert-SourceOracleVPhysicsResultObject `
        -Result $reversedAABB -RunID $runID -Request $request | Out-Null
} 'Reversed physics AABB was accepted'

$reversedEntityBounds = Copy-JSONValue $result
$reversedEntityBounds.entity_collision.collision_bounds.minimum.x = [double]2
Assert-Throws {
    Assert-SourceOracleVPhysicsResultObject `
        -Result $reversedEntityBounds -RunID $runID -Request $request | Out-Null
} 'Reversed engine collision bounds were accepted'

$movedEntity = Copy-JSONValue $result
$movedEntity.entity_collision.origin.z = [double]1
Assert-Throws {
    Assert-SourceOracleVPhysicsResultObject `
        -Result $movedEntity -RunID $runID -Request $request | Out-Null
} 'A result from outside the fixed probe transform was accepted'

$wrongTopology = Copy-JSONValue $result
$wrongTopology.physics.total_vertex_count = [int64]4
Assert-Throws {
    Assert-SourceOracleVPhysicsResultObject `
        -Result $wrongTopology -RunID $runID -Request $request | Out-Null
} 'Mismatched convex topology count was accepted'

$falseProp = Copy-JSONValue $result
$falseProp.validity.util_is_valid_prop = $false
Assert-Throws {
    Assert-SourceOracleVPhysicsResultObject `
        -Result $falseProp -RunID $runID -Request $request | Out-Null
} 'Successful fingerprint accepted util.IsValidProp=false'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'source-oracle-vphysics-contract-' + [Guid]::NewGuid().ToString('N')
)
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$resolvedFixture = [IO.Path]::GetFullPath($tempRoot)
Assert-True (
    $resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)
) 'Synthetic result directory escaped the system temp directory'
[void][IO.Directory]::CreateDirectory($resolvedFixture)
try {
    $resultPath = Join-Path $resolvedFixture 'result.json'
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText(
        $resultPath,
        ($result | ConvertTo-Json -Depth 32 -Compress),
        $utf8
    )
    $readResult = Read-SourceOracleVPhysicsResult `
        -Path $resultPath -RunID $runID -Request $request
    Assert-True ($readResult.request_id -ceq $requestID) 'Bounded result read failed'

    $oversizedPath = Join-Path $resolvedFixture 'oversized.json'
    [IO.File]::WriteAllBytes(
        $oversizedPath,
        [byte[]]::new([int]$request.limits.maximum_result_bytes + 1)
    )
    Assert-Throws {
        Read-SourceOracleVPhysicsResult `
            -Path $oversizedPath -RunID $runID -Request $request | Out-Null
    } 'Result byte cap was applied after an unbounded JSON read'
} finally {
    [IO.Directory]::Delete($resolvedFixture, $true)
}

$parserErrors = [Collections.Generic.List[System.Management.Automation.Language.ParseError]]::new()
foreach ($scriptName in @(
    'SourceOracleVPhysicsAttestationCommon.ps1',
    'Test-SourceOracleVPhysicsAttestation.ps1'
)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $toolRoot $scriptName),
        [ref]$tokens,
        [ref]$errors
    )
    foreach ($error in $errors) { $parserErrors.Add($error) }
}
Assert-True ($parserErrors.Count -eq 0) "PowerShell parser found $($parserErrors.Count) error(s)"

$probePath = Join-Path $toolRoot (
    'VPhysicsAttestationAddon\lua\autorun\server\garryspad_source_vphysics_attestation.lua'
)
$probe = Get-Content -Raw -Encoding UTF8 -LiteralPath $probePath
foreach ($required in @(
    'garryspad_source_vphysics_attestation_run',
    'run_token.txt',
    'request.json',
    'file.Open(path, "rb", "LUA")',
    'file.Open(path, "rb", "GAME")',
    'util.IsValidProp(request.model_path)',
    'physics:GetMeshConvexes()',
    'entity:OBBMins()',
    'entity:OBBMaxs()',
    'entity:GetCollisionBounds()',
    'physics:GetAABB()',
    'physics:GetMassCenter()',
    'physics:GetInertia()',
    'physics:GetMass()',
    'physics:GetMaterial()',
    'maximum_total_vertices',
    'maximum_result_bytes'
)) {
    Assert-True ($probe.Contains($required)) "Probe is missing fixed contract: $required"
}
foreach ($forbidden in @(
    '\bnet\.', '\bhttp\.', '\bHTTP\s*\(', '\bsteamworks\.',
    '\bRunString\b', '\bCompileString\b', '\brequire\s*\('
)) {
    Assert-True ($probe -notmatch $forbidden) "Probe contains forbidden behavior: $forbidden"
}
$openCalls = [regex]::Matches($probe, 'file\.Open\(')
Assert-True ($openCalls.Count -eq 2) (
    'Probe must have exactly one bounded generated-file and target-content open site'
)
Assert-True ($probe -notmatch '\bfile\.Read\b') (
    'Probe performs an unbounded generated or target file read'
)

Write-Output (
    'Owned-model VPhysics attestation contract tests passed ' +
    '(synthetic/static only; no GMod process, game asset, addon scan, or network was used)'
)
