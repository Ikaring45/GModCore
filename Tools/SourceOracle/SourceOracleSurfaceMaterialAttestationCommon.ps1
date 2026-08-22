Set-StrictMode -Version 3.0

# Contract-only validation for the surface/material-response portion of the
# isolated VPhysics oracle. This file performs no process, filesystem, game,
# addon, or network action. It is dot-sourced after the generic VPhysics JSON
# helpers have been defined.

$script:SourceOracleSurfaceContract = [pscustomobject][ordered]@{
    Schema = [int64]1
    AppID = [int64]4020
    Branch = 'x86-64'
    BuildID = '24721267'
    VPhysicsPath = 'bin/win64/vphysics.dll'
    VPhysicsSHA256 = '4ebd6149f885dfc518a44dd32dda64cbd6ebb3f938d43bdead70e80771b7e414'
    MapPath = 'garrysmod/maps/gm_flatgrass.bsp'
    MapSHA256 = '4dfd95ecb8f77a093e3079697b04c5be5675e8595c05639aaf57ad1541024d76'
    SurfaceInputs = @(
        [pscustomobject][ordered]@{
            path = 'sourceengine/scripts/surfaceproperties_manifest.txt'
            sha256 = 'd8bead334f07cd9f7cdfa30d691076b242ee469727aa0f0dcb734f3699d92a11'
        },
        [pscustomobject][ordered]@{
            path = 'sourceengine/scripts/surfaceproperties.txt'
            sha256 = 'b75f463e4a5b351c0f9a155c100659ae0384003ae910d092a07398e611056e32'
        },
        [pscustomobject][ordered]@{
            path = 'sourceengine/scripts/surfaceproperties_hl2.txt'
            sha256 = '6eb6c622f9d566515d0909d610c6f7213d327ed69545807696d74162ee3c0280'
        }
    )
    RequestedSurfaceNames = @('plastic', 'rubber')
    WorldTraces = @(
        [pscustomobject][ordered]@{
            id = 'flatgrass-center'
            start = [pscustomobject][ordered]@{ x = [int64]0; y = [int64]0; z = [int64]4096 }
            end = [pscustomobject][ordered]@{ x = [int64]0; y = [int64]0; z = [int64]-4096 }
        },
        [pscustomobject][ordered]@{
            id = 'flatgrass-offset'
            start = [pscustomobject][ordered]@{ x = [int64]1024; y = [int64]1024; z = [int64]4096 }
            end = [pscustomobject][ordered]@{ x = [int64]1024; y = [int64]1024; z = [int64]-4096 }
        }
    )
    PairID = 'plastic-against-rubber'
    MovingSurfaceName = 'plastic'
    FixedSurfaceName = 'rubber'
    AnchorTraceID = 'flatgrass-center'
    SeparationUnits = [int64]256
    ImpactSpeedUnitsPerSecond = [int64]128
    SampleDelayMilliseconds = [int64]50
    MaximumFrictionSnapshots = [int64]16
}

function Get-SourceOracleSurfaceFloat32String {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Field
    )

    $value = Get-SourceOracleVPhysicsString `
        -InputObject $InputObject -Name $Name -MaximumLength 32
    if ($value -cnotmatch '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:e[+-][0-9]{2,3})?$') {
        throw "$Field.$Name is not a finite lowercase %.9g decimal string"
    }
    $style = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $parsed = [single]0
    if (-not [single]::TryParse($value, $style, $culture, [ref]$parsed) -or
        [single]::IsNaN($parsed) -or [single]::IsInfinity($parsed)) {
        throw "$Field.$Name is not a finite Float32"
    }
    $roundTrip = $parsed.ToString('G9', $culture).ToLowerInvariant()
    if ($roundTrip -cne $value) {
        throw "$Field.$Name is not canonical %.9g Float32 round-trip text"
    }
    return $parsed
}

function Assert-SourceOracleSurfaceFloatVector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Vector,
        [Parameter(Mandatory)] [string]$Field
    )
    Assert-SourceOracleVPhysicsObjectShape -InputObject $Vector -Field $Field -Names @(
        'x', 'y', 'z'
    )
    foreach ($name in @('x', 'y', 'z')) {
        [void](Get-SourceOracleSurfaceFloat32String `
            -InputObject $Vector -Name $name -Field $Field)
    }
}

function Assert-SourceOracleSurfaceIntegerVector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Vector,
        [Parameter(Mandatory)] [string]$Field
    )
    Assert-SourceOracleVPhysicsObjectShape -InputObject $Vector -Field $Field -Names @(
        'x', 'y', 'z'
    )
    foreach ($name in @('x', 'y', 'z')) {
        [void](Get-SourceOracleVPhysicsInteger `
            -InputObject $Vector -Name $name -Minimum -32768 -Maximum 32768)
    }
}

function Assert-SourceOracleSurfaceProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Provenance,
        [Parameter(Mandatory)] [string]$RequestID
    )
    Assert-SourceOracleVPhysicsObjectShape -InputObject $Provenance `
        -Field 'surface provenance' -Names @(
            'app_id', 'branch', 'build_id', 'request_id', 'vphysics',
            'surface_inputs', 'map'
        )
    if ((Get-SourceOracleVPhysicsInteger -InputObject $Provenance `
        -Name 'app_id' -Minimum 4020 -Maximum 4020) -ne
        $script:SourceOracleSurfaceContract.AppID) {
        throw 'surface provenance AppID changed'
    }
    foreach ($pair in @(
        @('branch', $script:SourceOracleSurfaceContract.Branch),
        @('build_id', $script:SourceOracleSurfaceContract.BuildID),
        @('request_id', $RequestID)
    )) {
        $actual = Get-SourceOracleVPhysicsString `
            -InputObject $Provenance -Name $pair[0] -MaximumLength 64
        if ($actual -cne [string]$pair[1]) {
            throw "surface provenance $($pair[0]) changed"
        }
    }
    if ($RequestID -cnotmatch '^[0-9a-f]{32}$') {
        throw 'surface provenance request_id is not lowercase 32-hex'
    }

    foreach ($recordName in @('vphysics', 'map')) {
        $record = $Provenance.PSObject.Properties[$recordName].Value
        Assert-SourceOracleVPhysicsObjectShape -InputObject $record `
            -Field "surface provenance $recordName" -Names @('path', 'sha256')
        $path = Get-SourceOracleVPhysicsString `
            -InputObject $record -Name 'path' -MaximumLength 128
        $sha = Get-SourceOracleVPhysicsString `
            -InputObject $record -Name 'sha256' -MaximumLength 64
        Assert-SourceOracleVPhysicsSHA256 -Value $sha `
            -Field "surface provenance $recordName.sha256"
        $expectedPath = if ($recordName -ceq 'vphysics') {
            $script:SourceOracleSurfaceContract.VPhysicsPath
        } else {
            $script:SourceOracleSurfaceContract.MapPath
        }
        $expectedSHA = if ($recordName -ceq 'vphysics') {
            $script:SourceOracleSurfaceContract.VPhysicsSHA256
        } else {
            $script:SourceOracleSurfaceContract.MapSHA256
        }
        if ($path -cne $expectedPath -or $sha -cne $expectedSHA) {
            throw "surface provenance $recordName is not the fixed input"
        }
    }

    if ($Provenance.surface_inputs -isnot [array] -or
        @($Provenance.surface_inputs).Count -ne
            @($script:SourceOracleSurfaceContract.SurfaceInputs).Count) {
        throw 'surface provenance input count changed'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt @($Provenance.surface_inputs).Count; $index++) {
        $record = @($Provenance.surface_inputs)[$index]
        Assert-SourceOracleVPhysicsObjectShape -InputObject $record `
            -Field 'surface provenance input' -Names @('path', 'sha256')
        $path = Get-SourceOracleVPhysicsString `
            -InputObject $record -Name 'path' -MaximumLength 128
        $sha = Get-SourceOracleVPhysicsString `
            -InputObject $record -Name 'sha256' -MaximumLength 64
        Assert-SourceOracleVPhysicsSHA256 -Value $sha `
            -Field 'surface provenance input sha256'
        if (-not $seen.Add($path)) { throw "duplicate surface provenance path $path" }
        $expected = @($script:SourceOracleSurfaceContract.SurfaceInputs)[$index]
        if ([string]$expected.path -cne $path -or [string]$expected.sha256 -cne $sha) {
            throw "unknown or mismatched surface provenance input $path"
        }
    }
}

function Assert-SourceOracleSurfaceProbeRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$SurfaceProbe,
        [Parameter(Mandatory)] [string]$RequestID
    )
    Assert-SourceOracleVPhysicsObjectShape -InputObject $SurfaceProbe `
        -Field 'surface_probe' -Names @(
            'schema', 'provenance', 'requested_surface_names', 'world_traces',
            'controlled_pair'
        )
    [void](Get-SourceOracleVPhysicsInteger -InputObject $SurfaceProbe `
        -Name 'schema' -Minimum 1 -Maximum 1)
    Assert-SourceOracleSurfaceProvenance `
        -Provenance $SurfaceProbe.provenance -RequestID $RequestID

    if ($SurfaceProbe.requested_surface_names -isnot [array] -or
        @($SurfaceProbe.requested_surface_names).Count -ne
            @($script:SourceOracleSurfaceContract.RequestedSurfaceNames).Count) {
        throw 'surface_probe requested surface count changed'
    }
    $names = @($SurfaceProbe.requested_surface_names)
    for ($index = 0; $index -lt $names.Count; $index++) {
        if ($names[$index] -isnot [string] -or
            [string]$names[$index] -cne
                [string]$script:SourceOracleSurfaceContract.RequestedSurfaceNames[$index]) {
            throw 'surface_probe requested surfaces changed or are duplicated'
        }
    }

    if ($SurfaceProbe.world_traces -isnot [array] -or
        @($SurfaceProbe.world_traces).Count -ne
            @($script:SourceOracleSurfaceContract.WorldTraces).Count) {
        throw 'surface_probe world trace count changed'
    }
    for ($index = 0; $index -lt @($SurfaceProbe.world_traces).Count; $index++) {
        $trace = @($SurfaceProbe.world_traces)[$index]
        $expected = @($script:SourceOracleSurfaceContract.WorldTraces)[$index]
        Assert-SourceOracleVPhysicsObjectShape -InputObject $trace `
            -Field 'surface_probe world trace' -Names @('id', 'start', 'end')
        $id = Get-SourceOracleVPhysicsString `
            -InputObject $trace -Name 'id' -MaximumLength 64
        if ($id -cne [string]$expected.id) { throw 'surface_probe world trace id changed' }
        foreach ($endpoint in @('start', 'end')) {
            $vector = $trace.PSObject.Properties[$endpoint].Value
            Assert-SourceOracleSurfaceIntegerVector `
                -Vector $vector -Field "surface_probe world trace $endpoint"
            foreach ($axis in @('x', 'y', 'z')) {
                if ([int64]$vector.PSObject.Properties[$axis].Value -ne
                    [int64]$expected.PSObject.Properties[$endpoint].Value.PSObject.Properties[$axis].Value) {
                    throw "surface_probe world trace $id $endpoint changed"
                }
            }
        }
    }

    $pair = $SurfaceProbe.controlled_pair
    Assert-SourceOracleVPhysicsObjectShape -InputObject $pair `
        -Field 'surface_probe controlled_pair' -Names @(
            'pair_id', 'moving_surface_name', 'fixed_surface_name',
            'anchor_trace_id', 'separation_units', 'impact_speed_units_per_second',
            'sample_delay_milliseconds', 'maximum_friction_snapshots'
        )
    foreach ($definition in @(
        @('pair_id', $script:SourceOracleSurfaceContract.PairID),
        @('moving_surface_name', $script:SourceOracleSurfaceContract.MovingSurfaceName),
        @('fixed_surface_name', $script:SourceOracleSurfaceContract.FixedSurfaceName),
        @('anchor_trace_id', $script:SourceOracleSurfaceContract.AnchorTraceID)
    )) {
        $actual = Get-SourceOracleVPhysicsString `
            -InputObject $pair -Name $definition[0] -MaximumLength 64
        if ($actual -cne [string]$definition[1]) {
            throw "surface_probe controlled_pair $($definition[0]) changed"
        }
    }
    foreach ($definition in @(
        @('separation_units', $script:SourceOracleSurfaceContract.SeparationUnits),
        @('impact_speed_units_per_second',
            $script:SourceOracleSurfaceContract.ImpactSpeedUnitsPerSecond),
        @('sample_delay_milliseconds',
            $script:SourceOracleSurfaceContract.SampleDelayMilliseconds),
        @('maximum_friction_snapshots',
            $script:SourceOracleSurfaceContract.MaximumFrictionSnapshots)
    )) {
        $actual = Get-SourceOracleVPhysicsInteger `
            -InputObject $pair -Name $definition[0] -Minimum 1 -Maximum 4096
        if ($actual -ne [int64]$definition[1]) {
            throw "surface_probe controlled_pair $($definition[0]) changed"
        }
    }
    return $SurfaceProbe
}

function Assert-SourceOracleSurfaceMaterialAttestation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Result,
        [Parameter(Mandatory)] [object]$SurfaceProbe,
        [Parameter(Mandatory)] [string]$RequestID
    )
    [void](Assert-SourceOracleSurfaceProbeRequest `
        -SurfaceProbe $SurfaceProbe -RequestID $RequestID)
    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result `
        -Field 'surface_response' -Names @(
            'schema', 'kind', 'status', 'provenance', 'surface_lookups',
            'model_route', 'world_traces', 'controlled_pairs',
            'collision_samples', 'cleanup', 'issues'
        )
    [void](Get-SourceOracleVPhysicsInteger -InputObject $Result `
        -Name 'schema' -Minimum 1 -Maximum 1)
    if ((Get-SourceOracleVPhysicsString -InputObject $Result `
        -Name 'kind' -MaximumLength 80) -cne
        'source-surface-material-response-attestation') {
        throw 'surface_response.kind is unsupported'
    }
    $status = Get-SourceOracleVPhysicsString `
        -InputObject $Result -Name 'status' -MaximumLength 16
    if ($status -cnotin @('complete', 'partial', 'failure')) {
        throw 'surface_response.status is unsupported'
    }
    Assert-SourceOracleSurfaceProvenance `
        -Provenance $Result.provenance -RequestID $RequestID

    foreach ($arrayName in @(
        'surface_lookups', 'model_route', 'world_traces', 'controlled_pairs',
        'collision_samples', 'issues'
    )) {
        if ($Result.PSObject.Properties[$arrayName].Value -isnot [array]) {
            throw "surface_response.$arrayName must be a JSON array"
        }
    }

    $lookupNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $lookupIndices = [Collections.Generic.HashSet[int64]]::new()
    $lookupByName = @{}
    foreach ($lookup in @($Result.surface_lookups)) {
        Assert-SourceOracleVPhysicsObjectShape -InputObject $lookup `
            -Field 'surface lookup' -Names @(
                'requested_name', 'surface_index', 'reverse_name', 'data'
            )
        $name = Get-SourceOracleVPhysicsString `
            -InputObject $lookup -Name 'requested_name' -MaximumLength 128
        $index = Get-SourceOracleVPhysicsInteger `
            -InputObject $lookup -Name 'surface_index' -Minimum 0 -Maximum 65535
        $reverse = Get-SourceOracleVPhysicsString `
            -InputObject $lookup -Name 'reverse_name' -MaximumLength 128
        if (-not $lookupNames.Add($name) -or -not $lookupIndices.Add($index)) {
            throw 'surface_response contains a duplicate lookup name or index'
        }
        if ($name -cne $reverse) { throw "surface lookup reverse mismatch for $name" }
        Assert-SourceOracleVPhysicsObjectShape -InputObject $lookup.data `
            -Field 'surface lookup data' -Names @(
                'name', 'friction_coefficient', 'elasticity', 'density',
                'thickness', 'dampening', 'material'
            )
        $dataName = Get-SourceOracleVPhysicsString `
            -InputObject $lookup.data -Name 'name' -MaximumLength 128
        if ($dataName -cne $name) { throw "surface data reverse mismatch for $name" }
        foreach ($field in @(
            'friction_coefficient', 'elasticity', 'density', 'thickness', 'dampening'
        )) {
            [void](Get-SourceOracleSurfaceFloat32String `
                -InputObject $lookup.data -Name $field -Field 'surface lookup data')
        }
        [void](Get-SourceOracleVPhysicsInteger -InputObject $lookup.data `
            -Name 'material' -Minimum 0 -Maximum 255)
        $lookupByName[$name] = $lookup
    }

    $routeStages = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $routeByStage = @{}
    foreach ($route in @($Result.model_route)) {
        Assert-SourceOracleVPhysicsObjectShape -InputObject $route `
            -Field 'model route' -Names @(
                'stage', 'surface_name', 'surface_index', 'reverse_name'
            )
        $stage = Get-SourceOracleVPhysicsString `
            -InputObject $route -Name 'stage' -MaximumLength 32
        if ($stage -cnotin @(
            'mdl_bone', 'phy_solid', 'physobj', 'callback_our', 'callback_their'
        ) -or -not $routeStages.Add($stage)) {
            throw "surface_response contains an unknown or duplicate model route stage $stage"
        }
        $name = Get-SourceOracleVPhysicsString `
            -InputObject $route -Name 'surface_name' -MaximumLength 128
        [void](Get-SourceOracleVPhysicsInteger -InputObject $route `
            -Name 'surface_index' -Minimum 0 -Maximum 65535)
        $reverse = Get-SourceOracleVPhysicsString `
            -InputObject $route -Name 'reverse_name' -MaximumLength 128
        if ($name -cne $reverse) { throw "model route reverse mismatch at $stage" }
        $routeByStage[$stage] = $route
    }

    $traceIDs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($trace in @($Result.world_traces)) {
        Assert-SourceOracleVPhysicsObjectShape -InputObject $trace `
            -Field 'world trace' -Names @(
                'id', 'start', 'end', 'hit', 'hit_world', 'hit_position',
                'fraction', 'hit_texture', 'surface_index', 'reverse_name',
                'surface_data_name'
            )
        $id = Get-SourceOracleVPhysicsString `
            -InputObject $trace -Name 'id' -MaximumLength 64
        if (-not $traceIDs.Add($id)) { throw "duplicate world trace id $id" }
        foreach ($endpoint in @('start', 'end')) {
            Assert-SourceOracleSurfaceIntegerVector `
                -Vector $trace.PSObject.Properties[$endpoint].Value `
                -Field "world trace $id $endpoint"
        }
        Assert-SourceOracleSurfaceFloatVector `
            -Vector $trace.hit_position -Field "world trace $id hit_position"
        [void](Get-SourceOracleSurfaceFloat32String `
            -InputObject $trace -Name 'fraction' -Field "world trace $id")
        foreach ($booleanName in @('hit', 'hit_world')) {
            [void](Get-SourceOracleVPhysicsBoolean `
                -InputObject $trace -Name $booleanName)
        }
        [void](Get-SourceOracleVPhysicsString `
            -InputObject $trace -Name 'hit_texture' -MaximumLength 256)
        [void](Get-SourceOracleVPhysicsInteger -InputObject $trace `
            -Name 'surface_index' -Minimum 0 -Maximum 65535)
        $reverseName = Get-SourceOracleVPhysicsString `
            -InputObject $trace -Name 'reverse_name' -MaximumLength 128
        $surfaceDataName = Get-SourceOracleVPhysicsString `
            -InputObject $trace -Name 'surface_data_name' -MaximumLength 128
        if ($reverseName -cne $surfaceDataName) {
            throw "world trace $id surface data reverse mismatch"
        }
    }

    $snapshotOrdinals = [Collections.Generic.HashSet[int64]]::new()
    foreach ($snapshot in @($Result.controlled_pairs)) {
        Assert-SourceOracleVPhysicsObjectShape -InputObject $snapshot `
            -Field 'controlled pair snapshot' -Names @(
                'pair_id', 'snapshot_ordinal', 'material', 'material_other',
                'material_name', 'material_other_name', 'friction_coefficient',
                'normal_force', 'energy_absorbed', 'normal', 'contact_point'
            )
        $pairID = Get-SourceOracleVPhysicsString `
            -InputObject $snapshot -Name 'pair_id' -MaximumLength 64
        if ($pairID -cne [string]$SurfaceProbe.controlled_pair.pair_id) {
            throw 'controlled pair snapshot pair_id changed'
        }
        $ordinal = Get-SourceOracleVPhysicsInteger -InputObject $snapshot `
            -Name 'snapshot_ordinal' -Minimum 0 `
            -Maximum ([int64]$SurfaceProbe.controlled_pair.maximum_friction_snapshots - 1)
        if (-not $snapshotOrdinals.Add($ordinal)) {
            throw "duplicate controlled pair snapshot ordinal $ordinal"
        }
        foreach ($field in @('material', 'material_other')) {
            [void](Get-SourceOracleVPhysicsInteger -InputObject $snapshot `
                -Name $field -Minimum 0 -Maximum 65535)
        }
        foreach ($field in @('material_name', 'material_other_name')) {
            [void](Get-SourceOracleVPhysicsString `
                -InputObject $snapshot -Name $field -MaximumLength 128)
        }
        foreach ($field in @(
            'friction_coefficient', 'normal_force', 'energy_absorbed'
        )) {
            [void](Get-SourceOracleSurfaceFloat32String `
                -InputObject $snapshot -Name $field -Field 'controlled pair snapshot')
        }
        Assert-SourceOracleSurfaceFloatVector `
            -Vector $snapshot.normal -Field 'controlled pair snapshot normal'
        Assert-SourceOracleSurfaceFloatVector `
            -Vector $snapshot.contact_point -Field 'controlled pair snapshot contact_point'
    }

    $collisionIDs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($sample in @($Result.collision_samples)) {
        Assert-SourceOracleVPhysicsObjectShape -InputObject $sample `
            -Field 'collision sample' -Names @(
                'sample_id', 'pair_id', 'our_surface_index', 'their_surface_index',
                'our_surface_name', 'their_surface_name', 'hit_position',
                'hit_normal', 'hit_speed', 'our_old_velocity', 'their_old_velocity',
                'our_new_velocity', 'their_new_velocity',
                'our_old_angular_velocity', 'their_old_angular_velocity',
                'speed', 'delta_time'
            )
        $sampleID = Get-SourceOracleVPhysicsString `
            -InputObject $sample -Name 'sample_id' -MaximumLength 64
        if (-not $collisionIDs.Add($sampleID)) {
            throw "duplicate collision sample id $sampleID"
        }
        if ((Get-SourceOracleVPhysicsString -InputObject $sample `
            -Name 'pair_id' -MaximumLength 64) -cne
            [string]$SurfaceProbe.controlled_pair.pair_id) {
            throw 'collision sample pair_id changed'
        }
        foreach ($field in @('our_surface_index', 'their_surface_index')) {
            [void](Get-SourceOracleVPhysicsInteger -InputObject $sample `
                -Name $field -Minimum 0 -Maximum 65535)
        }
        foreach ($field in @('our_surface_name', 'their_surface_name')) {
            [void](Get-SourceOracleVPhysicsString `
                -InputObject $sample -Name $field -MaximumLength 128)
        }
        foreach ($field in @(
            'hit_position', 'hit_normal', 'hit_speed', 'our_old_velocity',
            'their_old_velocity', 'our_new_velocity', 'their_new_velocity',
            'our_old_angular_velocity', 'their_old_angular_velocity'
        )) {
            Assert-SourceOracleSurfaceFloatVector `
                -Vector $sample.PSObject.Properties[$field].Value `
                -Field "collision sample $field"
        }
        foreach ($field in @('speed', 'delta_time')) {
            [void](Get-SourceOracleSurfaceFloat32String `
                -InputObject $sample -Name $field -Field 'collision sample')
        }
    }

    Assert-SourceOracleVPhysicsObjectShape -InputObject $Result.cleanup `
        -Field 'surface_response.cleanup' -Names @(
            'spawned_entity_count', 'removed_entity_count', 'clean'
        )
    $spawned = Get-SourceOracleVPhysicsInteger -InputObject $Result.cleanup `
        -Name 'spawned_entity_count' -Minimum 0 -Maximum 2
    $removed = Get-SourceOracleVPhysicsInteger -InputObject $Result.cleanup `
        -Name 'removed_entity_count' -Minimum 0 -Maximum 2
    $clean = Get-SourceOracleVPhysicsBoolean -InputObject $Result.cleanup -Name 'clean'

    $issueSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($issue in @($Result.issues)) {
        if ($issue -isnot [string] -or [string]$issue -notmatch '^[a-z0-9][a-z0-9_.:-]{0,127}$' -or
            -not $issueSet.Add([string]$issue)) {
            throw 'surface_response issue is invalid or duplicated'
        }
    }
    if (@($Result.issues).Count -gt 32) { throw 'surface_response has too many issues' }

    if ($status -ceq 'complete') {
        $expectedNames = @($SurfaceProbe.requested_surface_names)
        if (@($Result.surface_lookups).Count -ne $expectedNames.Count) {
            throw 'complete surface_response is missing requested lookups'
        }
        foreach ($name in $expectedNames) {
            if (-not $lookupByName.ContainsKey([string]$name)) {
                throw "complete surface_response is missing lookup $name"
            }
        }
        $expectedStages = @(
            'mdl_bone', 'phy_solid', 'physobj', 'callback_our', 'callback_their'
        )
        if (@($Result.model_route).Count -ne $expectedStages.Count) {
            throw 'complete surface_response is missing a model route stage'
        }
        foreach ($stage in $expectedStages) {
            if (-not $routeByStage.ContainsKey($stage)) {
                throw "complete surface_response is missing model route $stage"
            }
        }
        if (@($Result.world_traces).Count -ne @($SurfaceProbe.world_traces).Count) {
            throw 'complete surface_response is missing a fixed world trace'
        }
        for ($index = 0; $index -lt @($SurfaceProbe.world_traces).Count; $index++) {
            $expectedTrace = @($SurfaceProbe.world_traces)[$index]
            $actualTrace = @($Result.world_traces | Where-Object {
                [string]$_.id -ceq [string]$expectedTrace.id
            })
            if ($actualTrace.Count -ne 1 -or
                -not [bool]$actualTrace[0].hit -or -not [bool]$actualTrace[0].hit_world) {
                throw "complete surface_response did not hit world for $($expectedTrace.id)"
            }
            foreach ($endpoint in @('start', 'end')) {
                foreach ($axis in @('x', 'y', 'z')) {
                    if ([int64]$actualTrace[0].PSObject.Properties[$endpoint].Value.PSObject.Properties[$axis].Value -ne
                        [int64]$expectedTrace.PSObject.Properties[$endpoint].Value.PSObject.Properties[$axis].Value) {
                        throw "complete surface_response trace coordinates changed"
                    }
                }
            }
        }
        if (@($Result.controlled_pairs).Count -lt 1 -or
            @($Result.controlled_pairs).Count -gt
                [int64]$SurfaceProbe.controlled_pair.maximum_friction_snapshots) {
            throw 'complete surface_response has no bounded friction snapshot'
        }
        if (@($Result.collision_samples).Count -ne 1) {
            throw 'complete surface_response must have one collision sample'
        }
        $moving = [string]$SurfaceProbe.controlled_pair.moving_surface_name
        $fixed = [string]$SurfaceProbe.controlled_pair.fixed_surface_name
        $movingLookup = $lookupByName[$moving]
        $fixedLookup = $lookupByName[$fixed]
        $collision = @($Result.collision_samples)[0]
        if ([string]$collision.our_surface_name -cne $moving -or
            [string]$collision.their_surface_name -cne $fixed -or
            [int64]$collision.our_surface_index -ne [int64]$movingLookup.surface_index -or
            [int64]$collision.their_surface_index -ne [int64]$fixedLookup.surface_index) {
            throw 'complete collision sample is not the requested controlled pair'
        }
        foreach ($snapshot in @($Result.controlled_pairs)) {
            if ([string]$snapshot.material_name -cne $moving -or
                [string]$snapshot.material_other_name -cne $fixed -or
                [int64]$snapshot.material -ne [int64]$movingLookup.surface_index -or
                [int64]$snapshot.material_other -ne [int64]$fixedLookup.surface_index) {
                throw 'complete friction snapshot is not the requested controlled pair'
            }
        }
        if (-not $clean -or $spawned -ne 2 -or $removed -ne 2) {
            throw 'complete surface_response did not prove clean entity cleanup'
        }
        if (@($Result.issues).Count -ne 0) {
            throw 'complete surface_response contains issues'
        }
    } else {
        if (@($Result.issues).Count -lt 1) {
            throw "$status surface_response must identify at least one issue"
        }
    }
    return $Result
}
