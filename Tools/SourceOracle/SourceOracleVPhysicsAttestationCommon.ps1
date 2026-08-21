Set-StrictMode -Version 3.0

# Contract-only support for a future, explicitly reviewed single-model
# VPhysics run. This file never starts a process, mounts content, reads the
# installed game tree, or performs network access.

$script:SourceOracleVPhysicsRequestByteCap = 65536
$script:SourceOracleVPhysicsPolicyCaps = [pscustomobject]@{
    MaximumMDLBytes = 33554432
    MaximumPHYBytes = 33554432
    MaximumSolids = 64
    MaximumConvexes = 1024
    MaximumVerticesPerConvex = 16384
    MaximumTotalVertices = 65536
    MaximumResultBytes = 8388608
    MaximumTimeoutSeconds = 60
}

function Assert-SourceOracleVPhysicsObjectShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string[]]$Names,
        [Parameter(Mandatory)] [string]$Field
    )

    if ($null -eq $InputObject -or $InputObject -is [array] -or
        $InputObject -is [string] -or $null -eq $InputObject.PSObject) {
        throw "$Field must be one JSON object"
    }
    $actual = @($InputObject.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) {
        throw "$Field has an unexpected property count"
    }
    foreach ($name in $Names) {
        if ($actual -cnotcontains $name) {
            throw "$Field is missing exact property $name"
        }
    }
}

function Get-SourceOracleVPhysicsString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int]$MaximumLength,
        [switch]$AllowEmpty
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string]) {
        throw "$Name must be a JSON string"
    }
    $value = [string]$property.Value
    if ((-not $AllowEmpty -and $value.Length -eq 0) -or
        $value.Length -gt $MaximumLength -or $value.IndexOf([char]0) -ge 0) {
        throw "$Name has an invalid string length or contains NUL"
    }
    return $value
}

function Get-SourceOracleVPhysicsInteger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int64]$Minimum,
        [Parameter(Mandatory)] [int64]$Maximum
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Name is missing" }
    $value = $property.Value
    $isInteger = $value -is [byte] -or $value -is [sbyte] -or
        $value -is [int16] -or $value -is [uint16] -or
        $value -is [int32] -or $value -is [uint32] -or
        $value -is [int64]
    if (-not $isInteger) { throw "$Name must be a JSON integer" }
    $converted = [int64]$value
    if ($converted -lt $Minimum -or $converted -gt $Maximum) {
        throw "$Name is outside $Minimum...$Maximum"
    }
    return $converted
}

function Get-SourceOracleVPhysicsFiniteNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -is [bool] -or
        $property.Value -isnot [ValueType]) {
        throw "$Name must be a JSON number"
    }
    $value = [double]$property.Value
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) {
        throw "$Name must be finite"
    }
    return $value
}

function Get-SourceOracleVPhysicsBoolean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [bool]) {
        throw "$Name must be a JSON boolean"
    }
    return [bool]$property.Value
}

function Assert-SourceOracleVPhysicsSHA256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Value,
        [Parameter(Mandatory)] [string]$Field
    )

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Field must be lowercase SHA-256 hex"
    }
}

function Assert-SourceOracleVPhysicsLogicalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Value,
        [Parameter(Mandatory)] [ValidateSet('.mdl', '.phy')] [string]$Extension,
        [Parameter(Mandatory)] [string]$Field
    )

    if ($Value.Length -gt 240 -or $Value -cnotmatch '^models/[a-z0-9_.-]+(?:/[a-z0-9_.-]+)*\.(mdl|phy)$' -or
        -not $Value.EndsWith($Extension, [StringComparison]::Ordinal) -or
        @($Value.Split('/') | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -ne 0) {
        throw "$Field is not one canonical lowercase GAME model path"
    }
}

function Assert-SourceOracleVPhysicsPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Policy)

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Policy -Field 'policy' -Names @(
        'search_path', 'allow_workshop', 'allow_installed_addons',
        'allow_user_lua', 'allow_network'
    )
    $searchPath = Get-SourceOracleVPhysicsString `
        -InputObject $Policy -Name 'search_path' -MaximumLength 8
    if ($searchPath -cne 'GAME') { throw 'policy.search_path must be GAME' }
    foreach ($name in @(
        'allow_workshop', 'allow_installed_addons', 'allow_user_lua', 'allow_network'
    )) {
        if (Get-SourceOracleVPhysicsBoolean -InputObject $Policy -Name $name) {
            throw "policy.$name must be false"
        }
    }
}

function Assert-SourceOracleVPhysicsLimits {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Limits)

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Limits -Field 'limits' -Names @(
        'maximum_mdl_bytes', 'maximum_phy_bytes', 'maximum_solids',
        'maximum_convexes', 'maximum_vertices_per_convex',
        'maximum_total_vertices', 'maximum_result_bytes', 'timeout_seconds'
    )
    $values = [ordered]@{
        maximum_mdl_bytes = Get-SourceOracleVPhysicsInteger -InputObject $Limits `
            -Name 'maximum_mdl_bytes' -Minimum 80 `
            -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumMDLBytes
        maximum_phy_bytes = Get-SourceOracleVPhysicsInteger -InputObject $Limits `
            -Name 'maximum_phy_bytes' -Minimum 16 `
            -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumPHYBytes
        maximum_solids = Get-SourceOracleVPhysicsInteger -InputObject $Limits `
            -Name 'maximum_solids' -Minimum 1 `
            -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumSolids
        maximum_convexes = Get-SourceOracleVPhysicsInteger -InputObject $Limits `
            -Name 'maximum_convexes' -Minimum 1 `
            -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumConvexes
        maximum_vertices_per_convex = Get-SourceOracleVPhysicsInteger `
            -InputObject $Limits -Name 'maximum_vertices_per_convex' -Minimum 3 `
            -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumVerticesPerConvex
        maximum_total_vertices = Get-SourceOracleVPhysicsInteger -InputObject $Limits `
            -Name 'maximum_total_vertices' -Minimum 3 `
            -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumTotalVertices
        maximum_result_bytes = Get-SourceOracleVPhysicsInteger -InputObject $Limits `
            -Name 'maximum_result_bytes' -Minimum 4096 `
            -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumResultBytes
        timeout_seconds = Get-SourceOracleVPhysicsInteger -InputObject $Limits `
            -Name 'timeout_seconds' -Minimum 5 `
            -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumTimeoutSeconds
    }
    if ($values.maximum_vertices_per_convex -gt $values.maximum_total_vertices) {
        throw 'maximum_vertices_per_convex exceeds maximum_total_vertices'
    }
    return [pscustomobject]$values
}

function Assert-SourceOracleVPhysicsRequestObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Request,
        [Parameter(Mandatory)] [object]$Allowlist
    )

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Request -Field 'request' -Names @(
        'schema', 'request_id', 'model_path', 'phy_path',
        'expected_mdl_sha256', 'expected_phy_sha256', 'ownership_reference',
        'policy', 'limits'
    )
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Request -Name 'schema' -Minimum 1 -Maximum 1)
    $requestID = Get-SourceOracleVPhysicsString `
        -InputObject $Request -Name 'request_id' -MaximumLength 32
    if ($requestID -cnotmatch '^[0-9a-f]{32}$') {
        throw 'request_id must be lowercase 32-hex'
    }
    $modelPath = Get-SourceOracleVPhysicsString `
        -InputObject $Request -Name 'model_path' -MaximumLength 240
    $phyPath = Get-SourceOracleVPhysicsString `
        -InputObject $Request -Name 'phy_path' -MaximumLength 240
    Assert-SourceOracleVPhysicsLogicalPath -Value $modelPath -Extension '.mdl' -Field 'model_path'
    Assert-SourceOracleVPhysicsLogicalPath -Value $phyPath -Extension '.phy' -Field 'phy_path'
    $derivedPHY = $modelPath.Substring(0, $modelPath.Length - 4) + '.phy'
    if ($phyPath -cne $derivedPHY) { throw 'phy_path is not derived from model_path' }

    $mdlSHA = Get-SourceOracleVPhysicsString `
        -InputObject $Request -Name 'expected_mdl_sha256' -MaximumLength 64
    $phySHA = Get-SourceOracleVPhysicsString `
        -InputObject $Request -Name 'expected_phy_sha256' -MaximumLength 64
    Assert-SourceOracleVPhysicsSHA256 -Value $mdlSHA -Field 'expected_mdl_sha256'
    Assert-SourceOracleVPhysicsSHA256 -Value $phySHA -Field 'expected_phy_sha256'
    $ownership = Get-SourceOracleVPhysicsString `
        -InputObject $Request -Name 'ownership_reference' -MaximumLength 128
    Assert-SourceOracleVPhysicsPolicy -Policy $Request.policy
    [void](Assert-SourceOracleVPhysicsLimits -Limits $Request.limits)

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Allowlist -Field 'allowlist' -Names @(
        'schema', 'models'
    )
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Allowlist -Name 'schema' -Minimum 1 -Maximum 1)
    if ($Allowlist.models -isnot [array] -or @($Allowlist.models).Count -ne 1) {
        throw 'owned-model allowlist must contain exactly one model'
    }
    $entry = @($Allowlist.models)[0]
    Assert-SourceOracleVPhysicsObjectShape -InputObject $entry -Field 'allowlist.models[0]' -Names @(
        'model_path', 'phy_path', 'mdl_sha256', 'phy_sha256', 'ownership_reference'
    )
    $allowedModel = Get-SourceOracleVPhysicsString `
        -InputObject $entry -Name 'model_path' -MaximumLength 240
    $allowedPHY = Get-SourceOracleVPhysicsString `
        -InputObject $entry -Name 'phy_path' -MaximumLength 240
    $allowedMDLSHA = Get-SourceOracleVPhysicsString `
        -InputObject $entry -Name 'mdl_sha256' -MaximumLength 64
    $allowedPHYSHA = Get-SourceOracleVPhysicsString `
        -InputObject $entry -Name 'phy_sha256' -MaximumLength 64
    $allowedOwnership = Get-SourceOracleVPhysicsString `
        -InputObject $entry -Name 'ownership_reference' -MaximumLength 128
    if ($modelPath -cne $allowedModel -or $phyPath -cne $allowedPHY -or
        $mdlSHA -cne $allowedMDLSHA -or $phySHA -cne $allowedPHYSHA -or
        $ownership -cne $allowedOwnership) {
        throw 'request does not exactly match the single owned-model allowlist entry'
    }
    return $Request
}

function Read-SourceOracleVPhysicsBoundedJSON {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$MaximumBytes,
        [Parameter(Mandatory)] [string]$Field
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open(
        $fullPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $MaximumBytes) {
            throw "$Field byte count $($stream.Length) is outside 1...$MaximumBytes"
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $cursor = 0
        while ($cursor -lt $bytes.Length) {
            $read = $stream.Read($bytes, $cursor, $bytes.Length - $cursor)
            if ($read -le 0) { throw "$Field ended before its retained length" }
            $cursor += $read
        }
    } finally {
        $stream.Dispose()
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try { $text = $utf8.GetString($bytes) }
    catch { throw "$Field is not strict UTF-8: $($_.Exception.Message)" }
    try { return $text | ConvertFrom-Json }
    catch { throw "$Field is not valid JSON: $($_.Exception.Message)" }
}

function Read-SourceOracleVPhysicsRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RequestPath,
        [Parameter(Mandatory)] [string]$AllowlistPath
    )

    $request = Read-SourceOracleVPhysicsBoundedJSON `
        -Path $RequestPath -MaximumBytes $script:SourceOracleVPhysicsRequestByteCap `
        -Field 'VPhysics request'
    $allowlist = Read-SourceOracleVPhysicsBoundedJSON `
        -Path $AllowlistPath -MaximumBytes $script:SourceOracleVPhysicsRequestByteCap `
        -Field 'owned-model allowlist'
    return Assert-SourceOracleVPhysicsRequestObject -Request $request -Allowlist $allowlist
}

function Assert-SourceOracleVPhysicsVector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Vector,
        [Parameter(Mandatory)] [string]$Field
    )

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Vector -Field $Field -Names @(
        'x', 'y', 'z'
    )
    return [pscustomobject]@{
        x = Get-SourceOracleVPhysicsFiniteNumber -InputObject $Vector -Name 'x'
        y = Get-SourceOracleVPhysicsFiniteNumber -InputObject $Vector -Name 'y'
        z = Get-SourceOracleVPhysicsFiniteNumber -InputObject $Vector -Name 'z'
    }
}

function Assert-SourceOracleVPhysicsResultObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Result,
        [Parameter(Mandatory)] [string]$RunID,
        [Parameter(Mandatory)] [object]$Request
    )

    if ($RunID -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Expected run_id is not lowercase 32-hex'
    }
    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result -Field 'result' -Names @(
        'schema', 'kind', 'enabled', 'command_line_enabled', 'run_id',
        'command_line_run_id', 'request_id', 'realm', 'finish_reason',
        'model_path', 'phy_path', 'policy', 'runtime', 'files', 'validity',
        'entity_collision', 'physics'
    )
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Result -Name 'schema' -Minimum 1 -Maximum 1)
    if ((Get-SourceOracleVPhysicsString -InputObject $Result -Name 'kind' -MaximumLength 64) `
        -cne 'owned-model-vphysics-attestation') {
        throw 'result.kind is unsupported'
    }
    foreach ($name in @('enabled', 'command_line_enabled')) {
        if (-not (Get-SourceOracleVPhysicsBoolean -InputObject $Result -Name $name)) {
            throw "result.$name must be true"
        }
    }
    foreach ($name in @('run_id', 'command_line_run_id')) {
        $value = Get-SourceOracleVPhysicsString -InputObject $Result -Name $name -MaximumLength 32
        if ($value -cne $RunID) { throw "result.$name does not match the launch" }
    }
    $requestID = Get-SourceOracleVPhysicsString `
        -InputObject $Result -Name 'request_id' -MaximumLength 32
    if ($requestID -cne [string]$Request.request_id) {
        throw 'result.request_id does not match the validated request'
    }
    if ((Get-SourceOracleVPhysicsString -InputObject $Result -Name 'realm' -MaximumLength 8) `
        -cne 'SERVER') { throw 'result.realm must be SERVER' }
    if ((Get-SourceOracleVPhysicsString -InputObject $Result -Name 'finish_reason' -MaximumLength 64) `
        -cne 'vphysics-attestation-complete') {
        throw 'result.finish_reason is not successful attestation completion'
    }
    foreach ($pair in @(
        @('model_path', [string]$Request.model_path),
        @('phy_path', [string]$Request.phy_path)
    )) {
        $value = Get-SourceOracleVPhysicsString `
            -InputObject $Result -Name $pair[0] -MaximumLength 240
        if ($value -cne $pair[1]) { throw "result.$($pair[0]) does not match request" }
    }
    Assert-SourceOracleVPhysicsPolicy -Policy $Result.policy

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.runtime -Field 'runtime' -Names @(
        'version', 'version_string', 'branch', 'is_windows', 'jit_arch', 'map'
    )
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Result.runtime `
        -Name 'version' -Minimum 1 -Maximum ([int32]::MaxValue))
    foreach ($name in @('version_string', 'branch', 'jit_arch', 'map')) {
        [void](Get-SourceOracleVPhysicsString `
            -InputObject $Result.runtime -Name $name -MaximumLength 128)
    }
    if (-not (Get-SourceOracleVPhysicsBoolean -InputObject $Result.runtime -Name 'is_windows')) {
        throw 'runtime.is_windows must be true'
    }

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.files -Field 'files' -Names @(
        'mdl', 'phy'
    )
    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.files.mdl -Field 'files.mdl' -Names @(
        'byte_count', 'sha256', 'magic', 'version', 'checksum'
    )
    $mdlBytes = Get-SourceOracleVPhysicsInteger -InputObject $Result.files.mdl `
        -Name 'byte_count' -Minimum 80 -Maximum ([int64]$Request.limits.maximum_mdl_bytes)
    $mdlSHA = Get-SourceOracleVPhysicsString `
        -InputObject $Result.files.mdl -Name 'sha256' -MaximumLength 64
    Assert-SourceOracleVPhysicsSHA256 -Value $mdlSHA -Field 'files.mdl.sha256'
    if ($mdlSHA -cne [string]$Request.expected_mdl_sha256) {
        throw 'files.mdl.sha256 does not match the owned allowlist request'
    }
    if ((Get-SourceOracleVPhysicsString -InputObject $Result.files.mdl `
        -Name 'magic' -MaximumLength 4) -cne 'IDST') {
        throw 'files.mdl.magic is not IDST'
    }
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Result.files.mdl `
        -Name 'version' -Minimum 48 -Maximum 48)
    $mdlChecksum = Get-SourceOracleVPhysicsInteger -InputObject $Result.files.mdl `
        -Name 'checksum' -Minimum ([int32]::MinValue) -Maximum ([int32]::MaxValue)

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.files.phy -Field 'files.phy' -Names @(
        'byte_count', 'sha256', 'header_byte_count', 'identifier', 'solid_count', 'checksum'
    )
    $phyBytes = Get-SourceOracleVPhysicsInteger -InputObject $Result.files.phy `
        -Name 'byte_count' -Minimum 16 -Maximum ([int64]$Request.limits.maximum_phy_bytes)
    $phySHA = Get-SourceOracleVPhysicsString `
        -InputObject $Result.files.phy -Name 'sha256' -MaximumLength 64
    Assert-SourceOracleVPhysicsSHA256 -Value $phySHA -Field 'files.phy.sha256'
    if ($phySHA -cne [string]$Request.expected_phy_sha256) {
        throw 'files.phy.sha256 does not match the owned allowlist request'
    }
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Result.files.phy `
        -Name 'header_byte_count' -Minimum 16 -Maximum 16)
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Result.files.phy `
        -Name 'identifier' -Minimum 0 -Maximum 0)
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Result.files.phy `
        -Name 'solid_count' -Minimum 1 -Maximum ([int64]$Request.limits.maximum_solids))
    $phyChecksum = Get-SourceOracleVPhysicsInteger -InputObject $Result.files.phy `
        -Name 'checksum' -Minimum ([int32]::MinValue) -Maximum ([int32]::MaxValue)
    if ($mdlChecksum -ne $phyChecksum) { throw 'MDL and PHY checksums differ' }
    if ($mdlBytes -le 0 -or $phyBytes -le 0) { throw 'attested files are empty' }

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.validity -Field 'validity' -Names @(
        'util_is_valid_model', 'util_is_valid_prop'
    )
    foreach ($name in @('util_is_valid_model', 'util_is_valid_prop')) {
        if (-not (Get-SourceOracleVPhysicsBoolean -InputObject $Result.validity -Name $name)) {
            throw "validity.$name must be true for a successful fingerprint"
        }
    }

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.entity_collision `
        -Field 'entity_collision' -Names @('origin', 'angles', 'obb', 'collision_bounds')
    $entityOrigin = Assert-SourceOracleVPhysicsVector `
        -Vector $Result.entity_collision.origin -Field 'entity_collision.origin'
    if ($entityOrigin.x -ne 0 -or $entityOrigin.y -ne 0 -or $entityOrigin.z -ne 0) {
        throw 'entity_collision.origin differs from the fixed probe origin'
    }
    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.entity_collision.angles `
        -Field 'entity_collision.angles' -Names @('pitch', 'yaw', 'roll')
    foreach ($name in @('pitch', 'yaw', 'roll')) {
        $value = Get-SourceOracleVPhysicsFiniteNumber `
            -InputObject $Result.entity_collision.angles -Name $name
        if ($value -ne 0) {
            throw 'entity_collision.angles differs from the fixed probe angle'
        }
    }
    foreach ($boundsName in @('obb', 'collision_bounds')) {
        $bounds = $Result.entity_collision.PSObject.Properties[$boundsName].Value
        Assert-SourceOracleVPhysicsObjectShape -InputObject $bounds `
            -Field "entity_collision.$boundsName" -Names @('minimum', 'maximum')
        $boundsMinimum = Assert-SourceOracleVPhysicsVector `
            -Vector $bounds.minimum -Field "entity_collision.$boundsName.minimum"
        $boundsMaximum = Assert-SourceOracleVPhysicsVector `
            -Vector $bounds.maximum -Field "entity_collision.$boundsName.maximum"
        if ($boundsMinimum.x -gt $boundsMaximum.x -or
            $boundsMinimum.y -gt $boundsMaximum.y -or
            $boundsMinimum.z -gt $boundsMaximum.z) {
            throw "entity_collision.$boundsName minimum exceeds maximum"
        }
    }

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.physics -Field 'physics' -Names @(
        'object_index', 'convex_count', 'total_vertex_count', 'vertices_per_convex',
        'topology_sha256', 'aabb', 'center_of_mass', 'inertia', 'mass', 'material',
        'convexes'
    )
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Result.physics `
        -Name 'object_index' -Minimum 0 -Maximum 0)
    $convexCount = Get-SourceOracleVPhysicsInteger -InputObject $Result.physics `
        -Name 'convex_count' -Minimum 1 -Maximum ([int64]$Request.limits.maximum_convexes)
    $declaredTotal = Get-SourceOracleVPhysicsInteger -InputObject $Result.physics `
        -Name 'total_vertex_count' -Minimum 3 `
        -Maximum ([int64]$Request.limits.maximum_total_vertices)
    if ($Result.physics.vertices_per_convex -isnot [array] -or
        @($Result.physics.vertices_per_convex).Count -ne $convexCount -or
        $Result.physics.convexes -isnot [array] -or
        @($Result.physics.convexes).Count -ne $convexCount) {
        throw 'physics convex arrays do not match convex_count'
    }
    $topologySHA = Get-SourceOracleVPhysicsString `
        -InputObject $Result.physics -Name 'topology_sha256' -MaximumLength 64
    Assert-SourceOracleVPhysicsSHA256 -Value $topologySHA -Field 'physics.topology_sha256'

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.physics.aabb -Field 'physics.aabb' `
        -Names @('minimum', 'maximum')
    $minimum = Assert-SourceOracleVPhysicsVector `
        -Vector $Result.physics.aabb.minimum -Field 'physics.aabb.minimum'
    $maximum = Assert-SourceOracleVPhysicsVector `
        -Vector $Result.physics.aabb.maximum -Field 'physics.aabb.maximum'
    if ($minimum.x -gt $maximum.x -or $minimum.y -gt $maximum.y -or
        $minimum.z -gt $maximum.z) { throw 'physics.aabb minimum exceeds maximum' }
    [void](Assert-SourceOracleVPhysicsVector `
        -Vector $Result.physics.center_of_mass -Field 'physics.center_of_mass')
    $inertia = Assert-SourceOracleVPhysicsVector `
        -Vector $Result.physics.inertia -Field 'physics.inertia'
    if ($inertia.x -lt 0 -or $inertia.y -lt 0 -or $inertia.z -lt 0) {
        throw 'physics.inertia contains a negative principal moment'
    }
    $mass = Get-SourceOracleVPhysicsFiniteNumber -InputObject $Result.physics -Name 'mass'
    if ($mass -le 0) { throw 'physics.mass must be positive' }
    [void](Get-SourceOracleVPhysicsString `
        -InputObject $Result.physics -Name 'material' -MaximumLength 128)

    $total = 0
    $counts = @($Result.physics.vertices_per_convex)
    $convexes = @($Result.physics.convexes)
    for ($convexIndex = 0; $convexIndex -lt $convexCount; $convexIndex++) {
        $rawCount = $counts[$convexIndex]
        $countCarrier = [pscustomobject]@{ value = $rawCount }
        $count = Get-SourceOracleVPhysicsInteger -InputObject $countCarrier `
            -Name 'value' -Minimum 3 `
            -Maximum ([int64]$Request.limits.maximum_vertices_per_convex)
        if (($count % 3) -ne 0) {
            throw "physics convex $convexIndex is not a triangle-list multiple"
        }
        if ($convexes[$convexIndex] -isnot [array] -or
            @($convexes[$convexIndex]).Count -ne $count) {
            throw "physics convex $convexIndex vertex array does not match its count"
        }
        $total += $count
        if ($total -gt [int64]$Request.limits.maximum_total_vertices) {
            throw 'physics vertices exceed maximum_total_vertices'
        }
        foreach ($vertex in @($convexes[$convexIndex])) {
            [void](Assert-SourceOracleVPhysicsVector `
                -Vector $vertex -Field "physics.convexes[$convexIndex].vertex")
        }
    }
    if ($total -ne $declaredTotal) {
        throw 'physics.total_vertex_count does not match convex topology'
    }
    return $Result
}

function Read-SourceOracleVPhysicsResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RunID,
        [Parameter(Mandatory)] [object]$Request
    )

    $capCarrier = [pscustomobject]@{
        maximum_result_bytes = $Request.limits.maximum_result_bytes
    }
    $cap = Get-SourceOracleVPhysicsInteger -InputObject $capCarrier `
        -Name 'maximum_result_bytes' -Minimum 4096 `
        -Maximum $script:SourceOracleVPhysicsPolicyCaps.MaximumResultBytes
    $result = Read-SourceOracleVPhysicsBoundedJSON `
        -Path $Path -MaximumBytes ([int]$cap) -Field 'VPhysics result'
    return Assert-SourceOracleVPhysicsResultObject `
        -Result $result -RunID $RunID -Request $Request
}
